#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import pathlib
import re
import signal
import shlex
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "hermes_delegate_mcp", ROOT / "etc" / "mcp" / "hermes_delegate_mcp.py"
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


STUB_SOURCE = '''#!/usr/bin/env python3
import json
import os
import sqlite3
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

CONFIG_PATH = os.path.join(os.environ.get("HERMES_HOME", ""), "config.yaml")


def _load_cfg():
    try:
        with open(CONFIG_PATH) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save_cfg(cfg):
    with open(CONFIG_PATH, "w") as fh:
        json.dump(cfg, fh)


if len(sys.argv) >= 5 and sys.argv[1] == "config" and sys.argv[2] == "set":
    cfg = _load_cfg()
    node = cfg
    parts = sys.argv[3].split(".")
    for part in parts[:-1]:
        if not isinstance(node.get(part), dict):
            node[part] = {}
        node = node[part]
    node[parts[-1]] = sys.argv[4]
    _save_cfg(cfg)
    sys.exit(0)

if len(sys.argv) >= 3 and sys.argv[1] == "config" and sys.argv[2] == "set":
    sys.exit(0)

if (len(sys.argv) >= 4 and sys.argv[1] == "config" and sys.argv[2] == "get"
        and sys.argv[3] == "agent.disabled_toolsets"):
    toolset_get_mode = control.get("toolset_get_mode", "ok")
    if toolset_get_mode == "fail":
        sys.stderr.write("config get: injected failure\\n")
        sys.exit(1)
    if "--json" not in sys.argv[4:]:
        sys.stderr.write("config get: called without --json, the type of the stored value is invisible\\n")
        sys.exit(2)
    cfg = _load_cfg()
    value = (cfg.get("agent") or {}).get("disabled_toolsets")
    if toolset_get_mode == "mismatch":
        value = "not-what-was-set"
    elif toolset_get_mode == "string":
        value = ",".join(value) if isinstance(value, list) else value
    elif toolset_get_mode == "short":
        value = ["terminal", "file"]
    record = control.get("toolset_record")
    if record:
        with open(record, "w") as fh:
            fh.write(json.dumps(value))
    sys.stdout.write(json.dumps(value) + "\\n")
    sys.exit(0)

if len(sys.argv) >= 2 and sys.argv[1] == "-z":
    mode = control.get("mode", "ok")
    if mode == "sleep":
        time.sleep(float(control.get("sleep_sec", 10)))
        sys.stdout.write("should not get here\\n")
        sys.exit(0)
    if mode == "sleep_with_output":
        sys.stdout.write("sleep-with-output-started\\n")
        sys.stdout.flush()
        time.sleep(float(control.get("sleep_sec", 10)))
        sys.stdout.write("should not get here\\n")
        sys.exit(0)
    if mode == "heartbeat":
        beats = int(control.get("beats", 4))
        gap = float(control.get("beat_gap_sec", 0.3))
        beat_path = os.path.join(
            os.environ.get("HERMES_HOME", ""), "state.db-wal")
        for _i in range(beats):
            time.sleep(gap)
            with open(beat_path, "a") as fh:
                fh.write("beat\\n")
        sys.stdout.write("stub-heartbeat-answer\\n")
        sys.exit(0)
    if mode == "ansi":
        sys.stdout.write("\\x1b[31mhello\\x1b[0m colored\\n")
        sys.exit(0)
    if mode == "fail":
        sys.stderr.write("stub failure\\n")
        sys.exit(1)
    if mode == "sqlite":
        steps = int(control.get("sqlite_steps", 3))
        gap = float(control.get("sqlite_gap_sec", 0.2))
        db_path = os.path.join(os.environ.get("HERMES_HOME", ""), "state.db")
        conn = sqlite3.connect(db_path)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(
            "CREATE TABLE sessions (id INTEGER PRIMARY KEY, name TEXT)")
        conn.execute(
            "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "session_id INTEGER, role TEXT, content TEXT, tool_call_id TEXT, "
            "tool_calls TEXT, tool_name TEXT, timestamp TEXT, "
            "finish_reason TEXT, reasoning TEXT)")
        conn.execute("INSERT INTO sessions (id, name) VALUES (1, 'test')")
        conn.commit()
        for i in range(steps):
            time.sleep(gap)
            tool_calls = json.dumps([{
                "function": {
                    "name": "terminal",
                    "arguments": json.dumps(
                        {"command": "pytest -q lib/x_%%d.py" %% i}),
                }
            }])
            conn.execute(
                "INSERT INTO messages (session_id, role, content, "
                "tool_calls) VALUES (1, 'assistant', ?, ?)",
                ("step %%d done" %% i, tool_calls))
            conn.commit()
        conn.close()
        sys.stdout.write("stub-sqlite-answer\\n")
        sys.exit(0)
    sys.stdout.write("stub-canned-answer\\n")
    sys.exit(0)

sys.exit(0)
'''


YAML_STUB_SOURCE = '''import json


def safe_load(stream):
    data = stream.read() if hasattr(stream, "read") else stream
    if isinstance(data, bytes):
        data = data.decode("utf-8")
    if not data.strip():
        return None
    return json.loads(data)


def safe_dump(data, stream=None, **kwargs):
    text = json.dumps(data)
    if stream is None:
        return text
    stream.write(text)
'''


def install_fake_venv_python(tmpdir):
    stubdir = os.path.join(tmpdir, "yamlstub")
    os.makedirs(stubdir, exist_ok=True)
    with open(os.path.join(stubdir, "yaml.py"), "w") as fh:
        fh.write(YAML_STUB_SOURCE)
    wrapper = os.path.join(tmpdir, "python")
    with open(wrapper, "w") as fh:
        fh.write("#!/bin/sh\nexec env PYTHONPATH=%s %s \"$@\"\n"
                 % (shlex.quote(stubdir), shlex.quote(sys.executable)))
    os.chmod(wrapper, 0o755)
    return wrapper


def make_stub(tmpdir, control_file):
    stub_path = os.path.join(tmpdir, "hermes-stub.py")
    with open(stub_path, "w") as fh:
        fh.write(STUB_SOURCE % {"control_file": control_file})
    os.chmod(stub_path, os.stat(stub_path).st_mode | stat.S_IEXEC)
    install_fake_venv_python(tmpdir)
    return stub_path


def write_control(control_file, **kwargs):
    with open(control_file, "w") as fh:
        json.dump(kwargs, fh)


def make_template_home(tmpdir, hardened=True):
    home = os.path.join(tmpdir, "template-home")
    os.makedirs(home, exist_ok=True)
    cfg = os.path.join(home, "config.yaml")
    with open(cfg, "w") as fh:
        fh.write(json.dumps({"model": {"provider": "local"}}) + "\n")
    if hardened:
        os.chmod(cfg, 0o444)
        os.chmod(home, 0o555)
    return home


def _scandir_denying(blocked):
    real = os.scandir

    def fake(path):
        if os.fspath(path) == blocked:
            raise PermissionError(blocked)
        return real(path)

    return fake


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
        os.environ[MOD.LOCK_DIR_VAR] = os.path.join(self.tmpdir, "locks")
        os.environ[MOD.RUNS_DIR_VAR] = os.path.join(self.tmpdir, "runs")
        os.environ["CBOX_HERMES_DELEGATE_PROVIDER"] = "local"
        os.environ["CBOX_HERMES_DELEGATE_BASE_URL"] = "http://127.0.0.1:11434"
        os.environ.pop("CBOX_HERMES_DELEGATE_MODEL", None)
        os.environ.pop("CBOX_HERMES_PROVIDER", None)
        os.environ.pop("CBOX_HERMES_MODEL_URL", None)
        os.environ.pop("CBOX_HERMES_MODEL_NAME", None)
        os.environ.pop("CBOX_OLLAMA_CONTEXT_LENGTH", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_TIMEOUT_SEC", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC", None)
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

    def _spawn_argv_for(self, which_fake):
        recorded = []
        real_popen = subprocess.Popen

        def recording_popen(*args, **kwargs):
            if list(args[0]).count("-z") == 1:
                recorded.append(list(args[0]))
            return real_popen(*args, **kwargs)

        with mock.patch.object(MOD.subprocess, "Popen", recording_popen), \
                mock.patch.object(MOD.shutil, "which", which_fake):
            result = MOD.run_hermes_delegate({"prompt": "hello"})
        self.assertFalse(result["isError"], result)
        self.assertIn("stub-canned-answer", result["content"][0]["text"])
        self.assertEqual(len(recorded), 1)
        return recorded[0]

    def test_spawn_argv_prefixed_with_setpriv_pdeathsig_when_available(self):
        fake_setpriv = os.path.join(self.tmpdir, "setpriv")
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
        which_fake = lambda name: fake_setpriv if name == "setpriv" \
            else shutil.which(name)
        argv = self._spawn_argv_for(which_fake)
        self.assertEqual(
            argv[:3], [fake_setpriv, "--pdeathsig", "KILL"])
        self.assertEqual(argv[3:], [self.stub, "-z", "hello", "--ignore-rules"])

    def test_spawn_argv_plain_when_setpriv_is_missing(self):
        which_fake = lambda name: None if name == "setpriv" \
            else shutil.which(name)
        argv = self._spawn_argv_for(which_fake)
        self.assertEqual(argv, [self.stub, "-z", "hello", "--ignore-rules"])

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

    def test_timeout_defaults_leave_room_for_long_local_work(self):
        self.assertEqual(MOD.DEFAULT_TIMEOUT_SEC, 0)
        self.assertEqual(MOD.DEFAULT_IDLE_TIMEOUT_SEC, 900)

    def test_hard_cap_error_names_the_var_and_the_running_generation(self):
        write_control(self.control_file, mode="sleep", sleep_sec=10)
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "1"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        text = result["content"][0]["text"]
        self.assertIn("wall-clock cap on the whole call", text)
        self.assertIn("CBOX_HERMES_DELEGATE_TIMEOUT_SEC", text)
        self.assertIn("still be finishing this generation", text)

    def test_idle_gate_fires_on_the_default_uncapped_call(self):
        write_control(self.control_file, mode="sleep", sleep_sec=10)
        os.environ[MOD.IDLE_TIMEOUT_VAR] = "1"
        started = time.monotonic()
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])
        text = result["content"][0]["text"]
        self.assertIn("stalled", text)
        self.assertIn("CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC", text)
        self.assertLess(time.monotonic() - started, 30)

    def test_idle_gate_fires_with_an_explicit_positive_cap(self):
        write_control(self.control_file, mode="sleep", sleep_sec=10)
        os.environ[MOD.TIMEOUT_VAR] = "60"
        os.environ[MOD.IDLE_TIMEOUT_VAR] = "1"
        started = time.monotonic()
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])
        text = result["content"][0]["text"]
        self.assertIn("stalled", text)
        self.assertIn("CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC", text)
        self.assertLess(time.monotonic() - started, 30)

    def test_explicit_cap_zero_idle_zero_lets_the_child_finish(self):
        os.environ[MOD.TIMEOUT_VAR] = "0"
        os.environ[MOD.IDLE_TIMEOUT_VAR] = "0"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        self.assertIn("stub-canned-answer", result["content"][0]["text"])

    def test_writes_in_the_ephemeral_home_count_as_progress(self):
        write_control(self.control_file, mode="heartbeat", beats=6,
                      beat_gap_sec=0.3)
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "60"
        os.environ["CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC"] = "2"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        self.assertIn("stub-heartbeat-answer", result["content"][0]["text"])

    def test_idle_timeout_zero_disables_the_stall_check(self):
        write_control(self.control_file, mode="sleep", sleep_sec=10)
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "1"
        os.environ["CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC"] = "0"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])
        text = result["content"][0]["text"]
        self.assertIn("timed out after 1s", text)
        self.assertNotIn("stalled", text)

    def test_idle_timeout_above_the_hard_cap_is_ignored(self):
        write_control(self.control_file, mode="sleep", sleep_sec=10)
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "1"
        os.environ["CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC"] = "900"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])
        text = result["content"][0]["text"]
        self.assertIn("timed out after 1s", text)
        self.assertNotIn("stalled", text)
        self.assertIn("no-progress check was off for this call", text)
        self.assertIn("900", text)

    def test_hard_cap_error_stays_quiet_when_the_idle_gate_was_active(self):
        write_control(self.control_file, mode="sleep", sleep_sec=10)
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "1"
        os.environ["CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC"] = "0"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertNotIn(
            "no-progress check was off", result["content"][0]["text"])

    def test_newest_mtime_clamps_a_future_timestamp(self):
        root = os.path.join(self.tmpdir, "future")
        os.makedirs(root)
        stamped = os.path.join(root, "seeded")
        with open(stamped, "w") as fh:
            fh.write("x")
        os.utime(stamped, (time.time() + 86400, time.time() + 86400))
        self.assertLessEqual(MOD.newest_mtime(root), time.time() + 1)

    def test_a_future_seeded_mtime_does_not_defeat_the_idle_gate(self):
        write_control(self.control_file, mode="heartbeat", beats=6,
                      beat_gap_sec=0.3)
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "60"
        os.environ["CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC"] = "2"
        future = time.time() + 86400
        seeded = os.path.join(self.template_home, "config.yaml")
        os.chmod(self.template_home, 0o755)
        os.chmod(seeded, 0o644)
        os.utime(seeded, (future, future))
        os.chmod(seeded, 0o444)
        os.chmod(self.template_home, 0o555)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        self.assertIn("stub-heartbeat-answer", result["content"][0]["text"])

    def test_newest_mtime_skips_a_directory_it_cannot_read(self):
        root = os.path.join(self.tmpdir, "denied")
        blocked = os.path.join(root, "blocked")
        os.makedirs(blocked)
        sibling = os.path.join(root, "sibling")
        with open(sibling, "w") as fh:
            fh.write("x")
        os.utime(sibling, (1000, 1000))
        with mock.patch("os.scandir", side_effect=_scandir_denying(blocked)):
            self.assertEqual(int(MOD.newest_mtime(root)), 1000)

    def test_newest_mtime_walks_subdirectories(self):
        root = os.path.join(self.tmpdir, "walk")
        os.makedirs(os.path.join(root, "a", "b"))
        deep = os.path.join(root, "a", "b", "leaf")
        with open(deep, "w") as fh:
            fh.write("x")
        os.utime(deep, (1000, 1000))
        self.assertEqual(int(MOD.newest_mtime(root)), 1000)
        os.utime(deep, (2000, 2000))
        self.assertEqual(int(MOD.newest_mtime(root)), 2000)

    def test_newest_mtime_survives_an_unreadable_tree(self):
        self.assertEqual(
            MOD.newest_mtime(os.path.join(self.tmpdir, "does-not-exist")), 0.0)

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
        self.assertIn("config set model.provider custom", calls)
        self.assertIn(
            "config set model.base_url http://127.0.0.1:11434", calls)
        self.assertIn("config set model.default qwen2.5:7b", calls)
        self.assertIn("config set model.context_length 65536", calls)

    def test_context_length_follows_the_ollama_context_var(self):
        marker = os.path.join(self.tmpdir, "marker_ctx.txt")
        write_control(self.control_file, marker=marker)
        os.environ["CBOX_OLLAMA_CONTEXT_LENGTH"] = "131072"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertIn("config set model.context_length 131072", calls)
        self.assertNotIn("config set model.context_length 65536", calls)

    def test_context_length_not_managed_for_hosted_providers(self):
        marker = os.path.join(self.tmpdir, "marker_ctx_hosted.txt")
        write_control(self.control_file, marker=marker)
        os.environ["CBOX_HERMES_DELEGATE_PROVIDER"] = "anthropic"
        os.environ.pop("CBOX_HERMES_DELEGATE_BASE_URL", None)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertNotIn("model.context_length", calls)

    def test_provider_for_cli_maps_cbox_enum_to_hermes_ids(self):
        self.assertEqual(MOD._provider_for_cli("local"), "custom")
        self.assertEqual(MOD._provider_for_cli("openai"), "openai-api")
        for name in ("nous", "openrouter", "anthropic"):
            self.assertEqual(MOD._provider_for_cli(name), name)

    def test_openai_provider_reaches_hermes_as_openai_api(self):
        marker = os.path.join(self.tmpdir, "marker_openai.txt")
        write_control(self.control_file, marker=marker)
        os.environ["CBOX_HERMES_DELEGATE_PROVIDER"] = "openai"
        os.environ.pop("CBOX_HERMES_DELEGATE_BASE_URL", None)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertIn("config set model.provider openai-api", calls)
        self.assertNotIn("config set model.provider openai\n", calls)

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

    def _run_and_record_pin(self, tag):
        marker = os.path.join(self.tmpdir, "marker_%s.txt" % tag)
        record = os.path.join(self.tmpdir, "record_%s.json" % tag)
        write_control(self.control_file, marker=marker, toolset_record=record)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        with open(marker) as fh:
            calls = fh.read()
        stored = None
        if os.path.exists(record):
            with open(record) as fh:
                stored = json.loads(fh.read())
        return result, calls, stored

    def test_disabled_toolsets_applied_in_qa_mode_by_default(self):
        os.environ.pop("CBOX_HERMES_DELEGATE_MODE", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS", None)
        result, calls, stored = self._run_and_record_pin("toolsets")
        self.assertFalse(result["isError"], result)
        self.assertEqual(stored, list(MOD.MANDATORY_DISABLED_TOOLSETS_ORDER))

    def test_pin_is_written_as_a_list_never_via_config_set(self):
        os.environ.pop("CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS", None)
        result, calls, stored = self._run_and_record_pin("toolsets_list")
        self.assertFalse(result["isError"], result)
        self.assertNotIn("config set agent.disabled_toolsets", calls)
        self.assertIsInstance(stored, list)
        self.assertEqual(stored, list(MOD.MANDATORY_DISABLED_TOOLSETS_ORDER))
        self.assertIn("config get agent.disabled_toolsets --json", calls)

    def test_comma_string_pin_is_refused_as_fail_open(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets_string.txt")
        write_control(
            self.control_file, marker=marker, toolset_get_mode="string")
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn("expected a JSON list", result["content"][0]["text"])
        with open(marker) as fh:
            calls = fh.read()
        self.assertNotIn(" -z ", calls)

    def test_disabled_toolsets_applied_with_custom_value(self):
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = "terminal,web"
        result, calls, stored = self._run_and_record_pin("toolsets2")
        self.assertFalse(result["isError"], result)
        self.assertEqual(stored, list(MOD.MANDATORY_DISABLED_TOOLSETS_ORDER))

    def test_disabled_toolsets_override_cannot_shrink_mandatory_set(self):
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = "terminal"
        result, calls, stored = self._run_and_record_pin("toolsets_shrink")
        self.assertFalse(result["isError"], result)
        self.assertEqual(stored, list(MOD.MANDATORY_DISABLED_TOOLSETS_ORDER))
        for name in ("code_execution", "delegation", "browser",
                     "computer_use"):
            self.assertIn(name, MOD.DEFAULT_DISABLED_TOOLSETS)

    def test_disabled_toolsets_override_can_add_beyond_mandatory_floor(self):
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = "extra_toolset"
        result, calls, stored = self._run_and_record_pin("toolsets_add")
        self.assertFalse(result["isError"], result)
        self.assertEqual(
            stored,
            list(MOD.MANDATORY_DISABLED_TOOLSETS_ORDER) + ["extra_toolset"])

    def test_default_disabled_toolsets_pinned_literal(self):
        self.assertEqual(
            MOD.DEFAULT_DISABLED_TOOLSETS,
            "terminal,file,web,code_execution,delegation,browser,"
            "computer_use")

    def test_tool_description_names_all_mandatory_toolsets(self):
        desc = MOD.tool_description()
        for name in MOD.DEFAULT_DISABLED_TOOLSETS.split(","):
            self.assertIn(name, desc)

    def test_tool_description_and_schema_require_english_prompts(self):
        for mode in ("qa", "agent"):
            os.environ["CBOX_HERMES_DELEGATE_MODE"] = mode
            self.assertIn("in English", MOD.tool_description())
        os.environ.pop("CBOX_HERMES_DELEGATE_MODE", None)
        props = MOD.build_tool()["inputSchema"]["properties"]
        self.assertIn("English", props["prompt"]["description"])
        self.assertIn("English", props["system"]["description"])

    def test_disabled_toolsets_falls_back_to_default_when_var_empty(self):
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = ""
        result, calls, stored = self._run_and_record_pin("toolsets3")
        self.assertFalse(result["isError"], result)
        self.assertEqual(stored, list(MOD.MANDATORY_DISABLED_TOOLSETS_ORDER))

    def test_disabled_toolsets_readback_confirms_the_pin(self):
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = "terminal,web"
        result, calls, stored = self._run_and_record_pin("toolsets4")
        self.assertFalse(result["isError"], result)
        self.assertIn("config get agent.disabled_toolsets --json", calls)
        self.assertLess(
            calls.index("config get agent.disabled_toolsets --json"),
            calls.index("-z "))

    def test_disabled_toolsets_readback_mismatch_refuses_the_call(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets5.txt")
        write_control(
            self.control_file, marker=marker, toolset_get_mode="mismatch")
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn("expected a JSON list", result["content"][0]["text"])

    def test_disabled_toolsets_readback_missing_name_refuses_the_call(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets_short.txt")
        write_control(
            self.control_file, marker=marker, toolset_get_mode="short")
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn("missing", result["content"][0]["text"])
        self.assertIn("did not take effect", result["content"][0]["text"])

    def test_disabled_toolsets_readback_failure_refuses_the_call(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets6.txt")
        write_control(
            self.control_file, marker=marker, toolset_get_mode="fail")
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn(
            "confirming the toolset pin", result["content"][0]["text"])

    def test_missing_venv_python_refuses_the_call(self):
        marker = os.path.join(self.tmpdir, "marker_nopython.txt")
        write_control(self.control_file, marker=marker)
        os.remove(os.path.join(self.tmpdir, "python"))
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn("venv", result["content"][0]["text"])
        with open(marker) as fh:
            calls = fh.read()
        self.assertNotIn(" -z ", calls)

    def test_writer_source_produces_a_list_not_a_string(self):
        self.assertIn("yaml.safe_load", MOD.DISABLED_TOOLSETS_WRITER)
        self.assertIn("yaml.safe_dump", MOD.DISABLED_TOOLSETS_WRITER)
        self.assertIn("[str(t) for t in items]", MOD.DISABLED_TOOLSETS_WRITER)
        self.assertNotIn("join(", MOD.DISABLED_TOOLSETS_WRITER)

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

    def test_progress_carries_live_step_count_and_last_tool_summary(self):
        write_control(self.control_file, mode="sqlite", sqlite_steps=4,
                      sqlite_gap_sec=0.2)
        recorded = []
        with mock.patch.object(
                MOD, "send", side_effect=lambda m: recorded.append(m)), \
                mock.patch.object(MOD, "PROGRESS_MIN_GAP_SEC", 0), \
                mock.patch.object(MOD, "HEARTBEAT_POLL_SEC", 0.05):
            self.assertTrue(MOD.begin_call(1, "tok"))
            text, err, meta = MOD.spawn_hermes("hi", None)
        MOD.end_call()
        self.assertIsNone(err, (text, err))
        self.assertIn("stub-sqlite-answer", text)
        pings = [
            m["params"]["message"] for m in recorded
            if m.get("method") == "notifications/progress"
        ]
        matches = [p for p in pings if "steps)" in p and "terminal:" in p]
        self.assertTrue(matches, pings)
        self.assertRegex(matches[0], r"steps\): terminal: pytest -q lib/x_")
        self.assertEqual(meta["steps"], 4)
        self.assertEqual(len(meta["tool_calls"]), 4)

    def test_run_saved_with_summary_and_permissions(self):
        write_control(self.control_file, mode="sqlite", sqlite_steps=2,
                      sqlite_gap_sec=0.05)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        text = result["content"][0]["text"]
        m = re.search(r"hermes-delegate run (\S+): (\d+) steps", text)
        self.assertIsNotNone(m, text)
        run_id, steps = m.group(1), int(m.group(2))
        self.assertTrue(MOD._valid_run_id(run_id))
        self.assertEqual(steps, 2)

        run_dir = os.path.join(os.environ[MOD.RUNS_DIR_VAR], run_id)
        self.assertTrue(os.path.isdir(run_dir))
        self.assertEqual(stat.S_IMODE(os.stat(run_dir).st_mode), 0o700)

        summary_path = os.path.join(run_dir, "summary.json")
        self.assertEqual(
            stat.S_IMODE(os.stat(summary_path).st_mode), 0o600)
        with open(summary_path) as fh:
            summary = json.load(fh)
        self.assertEqual(summary["run_id"], run_id)
        self.assertEqual(summary["outcome"], "ok")
        self.assertEqual(summary["mode"], "qa")
        self.assertEqual(summary["steps"], 2)
        self.assertEqual(len(summary["tool_calls"]), 2)
        self.assertTrue(summary["final_text_tail"])

        db_copy = os.path.join(run_dir, "state.db")
        self.assertTrue(os.path.isfile(db_copy))
        self.assertEqual(stat.S_IMODE(os.stat(db_copy).st_mode), 0o600)

    def test_no_automatic_pruning_after_many_runs(self):
        write_control(self.control_file, mode="sqlite", sqlite_steps=1,
                      sqlite_gap_sec=0.01)
        for _ in range(25):
            result = MOD.run_hermes_delegate({"prompt": "hi"})
            self.assertFalse(result["isError"], result)
        root = os.environ[MOD.RUNS_DIR_VAR]
        remaining = [n for n in os.listdir(root) if MOD._valid_run_id(n)]
        self.assertEqual(len(remaining), 25)

    def test_processed_runs_deletes_named_runs_and_reports_remaining(self):
        root = os.environ[MOD.RUNS_DIR_VAR]
        os.makedirs(root, exist_ok=True)
        ids = []
        for i in range(3):
            rid = "202601%02dT000000Z-%06x" % (i + 1, i)
            os.makedirs(os.path.join(root, rid))
            ids.append(rid)
        result = MOD.run_hermes_delegate(
            {"processed_runs": [ids[0], ids[1]]})
        self.assertFalse(result["isError"], result)
        text = result["content"][0]["text"]
        self.assertIn(ids[0], text)
        self.assertIn(ids[1], text)
        self.assertFalse(os.path.isdir(os.path.join(root, ids[0])))
        self.assertFalse(os.path.isdir(os.path.join(root, ids[1])))
        self.assertTrue(os.path.isdir(os.path.join(root, ids[2])))
        self.assertIn("1 unprocessed runs kept", text)
        self.assertIn(
            "delete processed ones with processed_runs", text)

    def test_processed_runs_unknown_id_reported_not_found(self):
        unknown = "20200101T000000Z-abcdef"
        result = MOD.run_hermes_delegate({"processed_runs": [unknown]})
        self.assertFalse(result["isError"], result)
        text = result["content"][0]["text"]
        self.assertIn("not found", text)
        self.assertIn(unknown, text)

    def test_processed_runs_malformed_ids_refused_without_filesystem_access(
            self):
        for bad in ("../x", "", "abc", "x" * 300, "a/b"):
            with mock.patch("os.lstat") as m_lstat, \
                    mock.patch("os.listdir") as m_listdir, \
                    mock.patch("shutil.rmtree") as m_rmtree:
                result = MOD.run_hermes_delegate(
                    {"processed_runs": [bad]})
            self.assertTrue(result["isError"], (bad, result))
            self.assertIn(
                "processed_runs", result["content"][0]["text"])
            m_lstat.assert_not_called()
            m_listdir.assert_not_called()
            m_rmtree.assert_not_called()

    def test_processed_runs_over_the_limit_refused(self):
        ids = ["202601%02dT000000Z-%06x" % (i % 28 + 1, i) for i in range(51)]
        result = MOD.run_hermes_delegate({"processed_runs": ids})
        self.assertTrue(result["isError"], result)
        self.assertIn("processed_runs", result["content"][0]["text"])

    def test_processed_runs_symlinked_entry_not_followed(self):
        root = os.environ[MOD.RUNS_DIR_VAR]
        os.makedirs(root, exist_ok=True)
        real_target = os.path.join(self.tmpdir, "sym_target")
        os.makedirs(real_target)
        keep_file = os.path.join(real_target, "keepme.txt")
        with open(keep_file, "w") as fh:
            fh.write("x")
        rid = "20260101T000000Z-abcdef"
        link_path = os.path.join(root, rid)
        os.symlink(real_target, link_path)
        result = MOD.run_hermes_delegate({"processed_runs": [rid]})
        self.assertFalse(result["isError"], result)
        text = result["content"][0]["text"]
        self.assertIn("not found", text)
        self.assertTrue(os.path.exists(keep_file))
        self.assertTrue(os.path.islink(link_path))

    def test_processed_runs_only_call_deletes_and_spawns_nothing(self):
        root = os.environ[MOD.RUNS_DIR_VAR]
        os.makedirs(root, exist_ok=True)
        rid = "20260101T000000Z-abcdef"
        os.makedirs(os.path.join(root, rid))
        with mock.patch.object(MOD, "spawn_hermes") as spawned:
            result = MOD.run_hermes_delegate({"processed_runs": [rid]})
        spawned.assert_not_called()
        self.assertFalse(result["isError"], result)
        text = result["content"][0]["text"]
        self.assertIn(rid, text)
        self.assertIn("unprocessed runs kept", text)
        self.assertFalse(os.path.isdir(os.path.join(root, rid)))

    def test_processed_runs_empty_array_call_spawns_nothing(self):
        with mock.patch.object(MOD, "spawn_hermes") as spawned:
            result = MOD.run_hermes_delegate({"processed_runs": []})
        spawned.assert_not_called()
        self.assertFalse(result["isError"], result)
        self.assertIn(
            "unprocessed runs kept", result["content"][0]["text"])

    def test_audit_record_carries_run_id_and_outcome(self):
        audit_path = os.path.join(self.tmpdir, "audit_runid.jsonl")
        os.environ["CBOX_HERMES_DELEGATE_AUDIT"] = audit_path
        try:
            result = MOD.run_hermes_delegate({"prompt": "hi"})
            self.assertFalse(result["isError"], result)
            m = re.search(
                r"hermes-delegate run (\S+):", result["content"][0]["text"])
            self.assertIsNotNone(m)
            run_id = m.group(1)
            with open(audit_path) as fh:
                rec = json.loads(fh.readline())
            self.assertEqual(rec["run_id"], run_id)
            self.assertEqual(rec["outcome"], "ok")
        finally:
            os.environ.pop("CBOX_HERMES_DELEGATE_AUDIT", None)

    def test_tool_description_byte_cap(self):
        for mode in ("qa", "agent"):
            os.environ["CBOX_HERMES_DELEGATE_MODE"] = mode
            size = len(MOD.tool_description().encode("utf-8"))
            self.assertLessEqual(size, 1200, (mode, size))
        os.environ.pop("CBOX_HERMES_DELEGATE_MODE", None)

    def test_output_log_created_at_spawn_and_contains_stub_output(self):
        write_control(self.control_file)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        m = re.search(
            r"hermes-delegate run (\S+):", result["content"][0]["text"])
        self.assertIsNotNone(m)
        run_id = m.group(1)
        log_path = os.path.join(
            os.environ[MOD.RUNS_DIR_VAR], run_id, "output.log")
        self.assertTrue(os.path.isfile(log_path))
        with open(log_path, "rb") as fh:
            content = fh.read()
        self.assertIn(b"[out] stub-canned-answer", content)

    def test_timeout_error_includes_run_id_and_steps(self):
        write_control(self.control_file, mode="sleep", sleep_sec=10)
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "1"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])
        text = result["content"][0]["text"]
        self.assertIn("run id:", text)
        self.assertIn("steps:", text)
        self.assertIn("last tool calls: none", text)
        self.assertIn("files changed: none", text)
        m = re.search(r"run id: (\S+)", text)
        self.assertIsNotNone(m, text)
        run_id = m.group(1)
        self.assertTrue(MOD._valid_run_id(run_id))
        run_dir = os.path.join(os.environ[MOD.RUNS_DIR_VAR], run_id)
        self.assertTrue(os.path.isdir(run_dir))
        with open(os.path.join(run_dir, "summary.json")) as fh:
            summary = json.load(fh)
        self.assertEqual(summary["outcome"], "timeout")

    def test_cancelled_call_returns_plain_error_without_run_detail(self):
        self.addCleanup(MOD._CANCEL.clear)
        self.addCleanup(MOD._CANCELLED_IDS.clear)
        pid_file = os.path.join(self.tmpdir, "pid_cancel_run.txt")
        stub_path = make_pid_stub(self.tmpdir, pid_file, 60)
        os.environ["HERMES_BIN"] = stub_path
        outcome = {}

        def runner():
            outcome["result"] = MOD.run_hermes_delegate({"prompt": "hi"})

        self.assertTrue(MOD.begin_call(42, None))
        thread = threading.Thread(target=runner, daemon=True)
        thread.start()
        pid = wait_for_pid_file(pid_file, 5)
        self.assertIsNotNone(pid, "the stub never recorded its pid")
        time.sleep(0.3)
        MOD.cancel_request(42)
        thread.join(timeout=10)
        MOD.end_call()
        self.assertFalse(thread.is_alive())
        result = outcome["result"]
        self.assertTrue(result["isError"])
        self.assertIn("cancelled", result["content"][0]["text"])
        self.assertNotIn("run id", result["content"][0]["text"])

    def test_symlinked_runs_dir_refused_but_call_still_succeeds(self):
        real_target = os.path.join(self.tmpdir, "real_runs_target")
        os.makedirs(real_target)
        link_path = os.path.join(self.tmpdir, "runs_symlink")
        os.symlink(real_target, link_path)
        os.environ[MOD.RUNS_DIR_VAR] = link_path
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        text = result["content"][0]["text"]
        self.assertIn("retention warning", text)
        self.assertIn("symlink", text)
        self.assertEqual(os.listdir(real_target), [])

    def test_read_state_db_summary_tolerates_missing_file(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        steps, calls, tail = MOD._read_state_db_summary(d)
        self.assertEqual((steps, calls, tail), (0, [], ""))

    def test_read_state_db_summary_tolerates_a_corrupt_file(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        with open(os.path.join(d, "state.db"), "wb") as fh:
            fh.write(b"not a sqlite database at all")
        steps, calls, tail = MOD._read_state_db_summary(d)
        self.assertEqual((steps, calls, tail), (0, [], ""))

    def test_read_state_db_summary_tolerates_a_locked_file(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "state.db")
        conn = sqlite3.connect(path)
        conn.execute(
            "CREATE TABLE messages (id INTEGER PRIMARY KEY, role TEXT, "
            "tool_calls TEXT, content TEXT)")
        conn.commit()
        conn.execute("BEGIN EXCLUSIVE")
        conn.execute("INSERT INTO messages (role) VALUES ('assistant')")
        try:
            steps, calls, tail = MOD._read_state_db_summary(d)
            self.assertEqual((steps, calls, tail), (0, [], ""))
        finally:
            conn.rollback()
            conn.close()

    def _evil_repo(self):
        repo = os.path.join(self.tmpdir, "evilrepo")
        os.makedirs(repo)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmpdir,
               "GIT_CONFIG_NOSYSTEM": "1"}
        run = lambda *a: subprocess.run(["git", "-C", repo] + list(a), check=True,
                                        env=env, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
        run("init", "-q")
        run("config", "user.email", "t@t")
        run("config", "user.name", "t")
        with open(os.path.join(repo, "a.txt"), "w") as fh:
            fh.write("one\n")
        run("add", "a.txt")
        run("commit", "-q", "-m", "init")
        marker = os.path.join(self.tmpdir, "evil_marker")
        hook = os.path.join(self.tmpdir, "evil.sh")
        with open(hook, "w") as fh:
            fh.write("#!/bin/sh\ntouch %s\ncat\n" % marker)
        os.chmod(hook, 0o755)
        with open(os.path.join(repo, ".gitattributes"), "w") as fh:
            fh.write("* filter=evil\n")
        run("config", "filter.evil.clean", hook)
        run("config", "filter.evil.process", hook)
        run("config", "core.fsmonitor", hook)
        return repo, marker

    def test_workspace_snapshot_never_runs_repository_code(self):
        repo, marker = self._evil_repo()
        with mock.patch.object(MOD.subprocess, "Popen",
                               side_effect=AssertionError("no process may be spawned")), \
                mock.patch.object(MOD.subprocess, "run",
                                  side_effect=AssertionError("no process may be spawned")):
            before = MOD._workspace_snapshot(repo)
            with open(os.path.join(repo, "a.txt"), "w") as fh:
                fh.write("two, longer content\n")
            with open(os.path.join(repo, "new.txt"), "w") as fh:
                fh.write("x\n")
            after = MOD._workspace_snapshot(repo)
        self.assertFalse(os.path.exists(marker))
        changed = MOD._files_changed_diff(before, after)
        self.assertIn("a.txt", changed)
        self.assertIn("new.txt", changed)
        self.assertFalse(any(p.startswith(".git" + os.sep) for p in changed))

    def test_workspace_snapshot_reports_deletions_and_skips_git_dir(self):
        repo, _marker = self._evil_repo()
        before = MOD._workspace_snapshot(repo)
        self.assertFalse(any(p == ".git" or p.startswith(".git" + os.sep) for p in before))
        os.remove(os.path.join(repo, "a.txt"))
        after = MOD._workspace_snapshot(repo)
        self.assertEqual(MOD._files_changed_diff(before, after), ["a.txt"])

    def test_workspace_snapshot_does_not_follow_directory_symlinks(self):
        root = os.path.join(self.tmpdir, "ws")
        outside = os.path.join(self.tmpdir, "outside")
        os.makedirs(root)
        os.makedirs(outside)
        with open(os.path.join(outside, "secret.txt"), "w") as fh:
            fh.write("s\n")
        os.symlink(outside, os.path.join(root, "link"))
        snap = MOD._workspace_snapshot(root)
        self.assertIn("link", snap)
        self.assertNotIn(os.path.join("link", "secret.txt"), snap)

    def test_workspace_snapshot_gives_up_past_the_file_cap(self):
        root = os.path.join(self.tmpdir, "many")
        os.makedirs(root)
        for i in range(6):
            open(os.path.join(root, "f%d" % i), "w").close()
        self.assertIsNone(MOD._workspace_snapshot(root, max_files=3))
        self.assertIsNotNone(MOD._workspace_snapshot(root, max_files=10))

    def test_sweep_runs_in_finally_on_normal_completion(self):
        called = []

        def fake_sweep(home, grace_sec=MOD.SWEEP_GRACE_SEC):
            called.append(home)

        with mock.patch.object(MOD, "_sweep_hermes_home", side_effect=fake_sweep):
            result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        self.assertEqual(len(called), 1)

    def test_sweep_runs_in_finally_on_the_generic_exception_path(self):
        called = []

        def fake_sweep(home, grace_sec=MOD.SWEEP_GRACE_SEC):
            called.append(home)

        with mock.patch.object(MOD, "_sweep_hermes_home", side_effect=fake_sweep), \
                mock.patch.object(
                    MOD.subprocess, "Popen", side_effect=RuntimeError("boom")):
            result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertEqual(len(called), 1)

    def test_create_run_for_writing_refuses_an_existing_dir(self):
        root, err = MOD._prepare_runs_dir()
        self.assertIsNone(err, err)
        run_id = MOD._new_run_id()
        os.makedirs(os.path.join(root, run_id))
        run_dir, fd, err = MOD._create_run_for_writing(run_id)
        self.assertIsNone(run_dir)
        self.assertIsNone(fd)
        self.assertIn("already exists", err)

    def test_progress_due_respects_the_gap_and_the_force_flag(self):
        self.assertTrue(MOD.begin_call(1, "tok"))
        try:
            with mock.patch.object(MOD, "PROGRESS_MIN_GAP_SEC", 100):
                MOD._CALL["last"] = time.monotonic()
                self.assertFalse(MOD.progress_due())
                self.assertTrue(MOD.progress_due(force=True))
        finally:
            MOD.end_call()

    def test_progress_due_false_without_an_active_call(self):
        MOD.end_call()
        self.assertFalse(MOD.progress_due())

    def test_live_activity_query_skipped_when_progress_is_not_due(self):
        write_control(self.control_file, mode="sqlite", sqlite_steps=3,
                      sqlite_gap_sec=0.2)
        calls = []

        def spy(home):
            calls.append(home)
            return 0, None

        with mock.patch.object(MOD, "progress_due", return_value=False), \
                mock.patch.object(MOD, "_read_latest_tool_call", side_effect=spy), \
                mock.patch.object(MOD, "HEARTBEAT_POLL_SEC", 0.05), \
                mock.patch.object(MOD, "send"):
            self.assertTrue(MOD.begin_call(1, "tok"))
            text, err, meta = MOD.spawn_hermes("hi", None)
        MOD.end_call()
        self.assertIsNone(err, (text, err))
        self.assertEqual(calls, [])

    def test_read_latest_tool_call_returns_only_the_last_call(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        conn = sqlite3.connect(os.path.join(d, "state.db"))
        conn.execute(
            "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "role TEXT, content TEXT, tool_calls TEXT)")
        for i in range(3):
            tool_calls = json.dumps([{
                "function": {
                    "name": "terminal",
                    "arguments": json.dumps({"command": "cmd-%d" % i}),
                }
            }])
            conn.execute(
                "INSERT INTO messages (role, content, tool_calls) VALUES "
                "('assistant', ?, ?)", ("step-%d" % i, tool_calls))
        conn.commit()
        conn.close()
        steps, last_call = MOD._read_latest_tool_call(d)
        self.assertEqual(steps, 3)
        self.assertEqual(last_call, ("terminal", "cmd-2"))

    def test_read_latest_tool_call_tolerates_a_missing_file(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        steps, last_call = MOD._read_latest_tool_call(d)
        self.assertEqual((steps, last_call), (0, None))


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
        self.env[MOD.LOCK_DIR_VAR] = os.path.join(self.tmpdir, "locks")
        self.env[MOD.RUNS_DIR_VAR] = os.path.join(self.tmpdir, "runs")
        self.env["CBOX_HERMES_DELEGATE_PROVIDER"] = "local"
        self.env["CBOX_HERMES_DELEGATE_BASE_URL"] = "http://127.0.0.1:11434"
        self.env.pop("CBOX_OLLAMA_CONTEXT_LENGTH", None)
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
import json
import os
CONFIG_PATH = os.path.join(os.environ.get("HERMES_HOME", ""), "config.yaml")
if len(sys.argv) >= 3 and sys.argv[1] == "config" and sys.argv[2] == "set":
    sys.exit(0)
if (len(sys.argv) >= 4 and sys.argv[1] == "config" and sys.argv[2] == "get"
        and sys.argv[3] == "agent.disabled_toolsets"):
    with open(CONFIG_PATH) as fh:
        cfg = json.load(fh)
    sys.stdout.write(json.dumps((cfg.get("agent") or {}).get("disabled_toolsets")) + "\\n")
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
        os.environ[MOD.RUNS_DIR_VAR] = os.path.join(self.tmpdir, "runs")
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
        install_fake_venv_python(self.tmpdir)
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


class EmptyEnvDefaultsTests(unittest.TestCase):
    """A rendered MCP entry supplies every declared env key, so an unset cbox var
    arrives as an EMPTY STRING rather than as a missing key. os.environ.get(k, d)
    returns "" in that case, not d - which is how the lock dir became "" and made
    every delegate call die on makedirs("")."""

    EMPTY_VARS = (
        MOD.BIN_VAR,
        MOD.TEMPLATE_HOME_VAR,
        MOD.LOCK_DIR_VAR,
        MOD.AUDIT_VAR,
    )

    def test_empty_env_values_fall_back_to_defaults(self):
        env = {v: "" for v in self.EMPTY_VARS}
        with mock.patch.dict(os.environ, env, clear=False):
            self.assertEqual(MOD.hermes_bin(), MOD.DEFAULT_BIN)
            self.assertEqual(MOD.template_home(), MOD.DEFAULT_TEMPLATE_HOME)
            self.assertTrue(MOD.audit_path(),
                            "audit path must never resolve to an empty string")
            self.assertNotEqual(MOD.audit_path(), "")

    def test_empty_lock_dir_still_acquires_a_slot(self):
        fallback = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, fallback, True)
        with mock.patch.dict(os.environ, {MOD.LOCK_DIR_VAR: ""}, clear=False), \
                mock.patch.object(MOD, "DEFAULT_LOCK_DIR", fallback):
            handle, err = MOD.acquire_slot()
            self.assertTrue(os.path.exists(os.path.join(fallback, "slot.0")))
            self.assertIsNone(
                err,
                "an empty lock dir must fall back to the default, not fail: %r" % (err,))
            self.assertIsNotNone(handle)
            MOD.release_slot(handle)


class PerCallEffortTests(unittest.TestCase):
    """The container default is a floor for convenience, not a cage: the caller
    picks the effort per task, the same way the codex tiers take model/effort
    per call. The accepted set stays narrow because a Qwen3.x chat template
    raises on anything outside it and that surfaces as HTTP 500, not as a
    config error."""

    def test_schema_offers_the_narrow_enum(self):
        tool = MOD.build_tool()
        props = tool["inputSchema"]["properties"]
        self.assertIn("effort", props)
        self.assertEqual(list(props["effort"]["enum"]), list(MOD.VALID_EFFORTS))
        self.assertNotIn("effort", tool["inputSchema"]["required"])

    def test_override_beats_the_container_default(self):
        with mock.patch.dict(os.environ, {MOD.EFFORT_VAR: "xhigh"}, clear=False):
            self.assertEqual(MOD._effort_setting(), "xhigh")
            self.assertEqual(MOD._effort_setting("low"), "low")

    def test_no_override_falls_back_to_the_container_default(self):
        with mock.patch.dict(os.environ, {MOD.EFFORT_VAR: "medium"}, clear=False):
            self.assertEqual(MOD._effort_setting(None), "medium")

    def test_unset_everywhere_leaves_it_to_the_model(self):
        with mock.patch.dict(os.environ, {MOD.EFFORT_VAR: ""}, clear=False):
            self.assertIsNone(MOD._effort_setting())
            self.assertIsNone(MOD._effort_setting(""))

    def test_value_outside_the_enum_is_refused(self):
        for bad in ("high", "max", "ultra", "minimal", "banana"):
            self.assertIs(MOD._effort_setting(bad), False,
                          "%r must be refused: the chat template raises on it" % bad)

    def test_caller_supplied_bad_effort_is_refused_before_spawning(self):
        with mock.patch.object(MOD, "spawn_hermes") as spawned:
            out = MOD.run_hermes_delegate({"prompt": "hi", "effort": "max"})
        spawned.assert_not_called()
        body = json.dumps(out)
        self.assertIn("effort must be one of", body)


class AgentModeTests(unittest.TestCase):
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
        os.environ["CBOX_HERMES_DELEGATE_MODE"] = "agent"
        for k in ("CBOX_HERMES_DELEGATE_MODEL", "CBOX_HERMES_PROVIDER",
                  "CBOX_HERMES_MODEL_URL", "CBOX_HERMES_MODEL_NAME",
                  "CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS",
                  "CBOX_DELEGATION_DEPTH", "CBOX_MCP_DEPTH",
                  "CBOX_HERMES_DELEGATE_LOCK_DIR", "CBOX_SCOPE_ROOT"):
            os.environ.pop(k, None)
        os.environ["CBOX_HERMES_DELEGATE_LOCK_DIR"] = os.path.join(self.tmpdir, "locks")
        os.environ[MOD.RUNS_DIR_VAR] = os.path.join(self.tmpdir, "runs")
        self.guard_script = os.path.join(self.tmpdir, "hermes_guard_bridge.py")
        with open(self.guard_script, "w") as fh:
            fh.write("import sys\nsys.exit(0)\n")
        os.chmod(self.guard_script, 0o444)
        self.hooks_file = os.path.join(self.tmpdir, "hooks.yaml")
        self._write_hooks_file([{"matcher": "terminal",
                                 "command": "python3 " + self.guard_script,
                                 "timeout": 10}])
        os.environ["CBOX_HERMES_DELEGATE_HOOKS_FILE"] = self.hooks_file

    def _write_hooks_file(self, entries):
        if os.path.exists(self.hooks_file):
            os.chmod(self.hooks_file, 0o644)
        with open(self.hooks_file, "w") as fh:
            fh.write(json.dumps({"hooks": {"pre_tool_call": entries}}) + "\n")
        os.chmod(self.hooks_file, 0o444)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_backup)
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _run_and_record_pin(self, tag):
        marker = os.path.join(self.tmpdir, "marker_%s.txt" % tag)
        record = os.path.join(self.tmpdir, "record_%s.json" % tag)
        write_control(self.control_file, marker=marker, toolset_record=record)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        stored = None
        if os.path.exists(record):
            with open(record) as fh:
                stored = json.loads(fh.read())
        return result, stored

    def test_agent_mode_is_valid_and_qa_stays_default(self):
        self.assertIsNone(MOD.validate_mode("agent"))
        self.assertEqual(MOD.DEFAULT_MODE, "qa")
        self.assertIn("agent", MOD.VALID_MODES)
        self.assertNotIn("workspace", MOD.VALID_MODES)

    def test_agent_floor_keeps_terminal_and_file_but_pins_fanout_off(self):
        floor = MOD.mandatory_disabled_toolsets("agent")
        for name in ("code_execution", "web", "delegation", "browser", "computer_use", "cronjob"):
            self.assertIn(name, floor)
        for name in ("terminal", "file"):
            self.assertNotIn(name, floor)
        self.assertEqual(MOD.mandatory_disabled_toolsets("qa"),
                         MOD.MANDATORY_DISABLED_TOOLSETS_ORDER)

    def test_agent_mode_pins_its_floor_and_runs_with_hooks_present(self):
        result, stored = self._run_and_record_pin("agent")
        self.assertFalse(result["isError"], result)
        self.assertEqual(stored, list(MOD.AGENT_MANDATORY_DISABLED_TOOLSETS_ORDER))

    def test_agent_mode_override_extends_the_floor_never_shrinks_it(self):
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = "memory,delegation"
        result, stored = self._run_and_record_pin("agent_override")
        self.assertFalse(result["isError"], result)
        self.assertEqual(stored, list(MOD.AGENT_MANDATORY_DISABLED_TOOLSETS_ORDER) + ["memory"])

    def test_agent_mode_refuses_without_the_guard_hooks_block(self):
        os.environ["CBOX_HERMES_DELEGATE_HOOKS_FILE"] = os.path.join(self.tmpdir, "missing.yaml")
        result, stored = self._run_and_record_pin("agent_nohooks")
        self.assertTrue(result["isError"], result)
        text = result["content"][0]["text"]
        self.assertIn("CBOX_HERMES_HOOKS=on", text)
        self.assertIn("agent mode", text)

    def test_agent_mode_refuses_a_writable_hooks_block(self):
        os.chmod(self.hooks_file, 0o666)
        result, stored = self._run_and_record_pin("agent_writable")
        self.assertTrue(result["isError"], result)
        self.assertIn("writable", result["content"][0]["text"])

    def test_qa_mode_ignores_the_hooks_file_entirely(self):
        os.environ["CBOX_HERMES_DELEGATE_MODE"] = "qa"
        os.environ["CBOX_HERMES_DELEGATE_HOOKS_FILE"] = os.path.join(self.tmpdir, "missing.yaml")
        result, stored = self._run_and_record_pin("qa_nohooks")
        self.assertFalse(result["isError"], result)
        self.assertEqual(stored, list(MOD.MANDATORY_DISABLED_TOOLSETS_ORDER))

    def _fresh_home(self, name):
        home = os.path.join(self.tmpdir, name)
        os.makedirs(home)
        with open(os.path.join(home, "config.yaml"), "w") as fh:
            fh.write(json.dumps({"model": {"provider": "custom"}}) + "\n")
        return home

    def test_guard_hooks_land_in_the_ephemeral_config_and_are_accepted(self):
        home = self._fresh_home("eph")
        env_base = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home}
        err = MOD._apply_guard_hooks(home, env_base)
        self.assertIsNone(err)
        with open(os.path.join(home, "config.yaml")) as fh:
            text = fh.read()
        self.assertIn("pre_tool_call", text)
        self.assertIn("hermes_guard_bridge.py", text)
        self.assertIn("hooks_auto_accept", text)
        self.assertIn("provider", text)
        self.assertEqual(env_base.get("HERMES_ACCEPT_HOOKS"), "1")

    def test_qa_mode_never_sets_hook_acceptance(self):
        os.environ["CBOX_HERMES_DELEGATE_MODE"] = "qa"
        home = self._fresh_home("eph_qa")
        env_base = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home}
        err = MOD._apply_config(home, env_base)
        self.assertIsNone(err, err)
        self.assertNotIn("HERMES_ACCEPT_HOOKS", env_base)

    def test_hooks_block_without_a_pre_tool_call_hook_is_refused(self):
        self._write_hooks_file([])
        result, stored = self._run_and_record_pin("agent_emptyhooks")
        self.assertTrue(result["isError"], result)
        self.assertIn("pre_tool_call", result["content"][0]["text"])

    def test_hooks_block_naming_a_missing_guard_script_is_refused(self):
        self._write_hooks_file([{"matcher": "terminal",
                                 "command": "python3 " + os.path.join(self.tmpdir, "gone.py"),
                                 "timeout": 10}])
        result, stored = self._run_and_record_pin("agent_goneguard")
        self.assertTrue(result["isError"], result)
        self.assertIn("gone.py", result["content"][0]["text"])

    def test_hooks_block_naming_a_writable_guard_script_is_refused(self):
        os.chmod(self.guard_script, 0o666)
        result, stored = self._run_and_record_pin("agent_wguard")
        self.assertTrue(result["isError"], result)
        self.assertIn("writable", result["content"][0]["text"])

    def test_agent_workspace_refuses_a_directory_outside_a_git_tree(self):
        os.environ["CBOX_SCOPE_ROOT"] = self.tmpdir
        root, err = MOD.agent_workspace()
        self.assertIsNone(root)
        self.assertIn("git work tree", err)
        os.environ.pop("CBOX_SCOPE_ROOT", None)
        root, err = MOD.agent_workspace()
        self.assertIsNone(err, err)
        self.assertEqual(root, os.getcwd())

    def test_workspace_dir_prefers_scope_root_and_falls_back_to_cwd(self):
        os.environ["CBOX_SCOPE_ROOT"] = self.tmpdir
        self.assertEqual(MOD.workspace_dir(), self.tmpdir)
        os.environ["CBOX_SCOPE_ROOT"] = os.path.join(self.tmpdir, "does-not-exist")
        self.assertEqual(MOD.workspace_dir(), os.getcwd())
        os.environ.pop("CBOX_SCOPE_ROOT", None)
        self.assertEqual(MOD.workspace_dir(), os.getcwd())

    def test_scope_root_reaches_the_child_environment(self):
        os.environ["CBOX_SCOPE_ROOT"] = self.tmpdir
        os.environ["CBOX_SCOPE_SLUG"] = "-x"
        self.assertEqual(MOD._scope_env(), {"CBOX_SCOPE_ROOT": self.tmpdir, "CBOX_SCOPE_SLUG": "-x"})

    def test_tool_description_names_the_active_mode(self):
        self.assertIn("agent mode", MOD.tool_description())
        self.assertIn("workspace", MOD.tool_description())
        os.environ["CBOX_HERMES_DELEGATE_MODE"] = "qa"
        self.assertIn("qa mode", MOD.tool_description())
        self.assertNotIn("agent mode", MOD.tool_description())


PID_STUB_SOURCE = '''#!/usr/bin/env python3
import json
import os
import sys
import time

PID_FILE = %(pid_file)r
SLEEP_SEC = %(sleep_sec)r
CONFIG_PATH = os.path.join(os.environ.get("HERMES_HOME", ""), "config.yaml")
if len(sys.argv) >= 3 and sys.argv[1] == "config" and sys.argv[2] == "set":
    sys.exit(0)
if (len(sys.argv) >= 4 and sys.argv[1] == "config" and sys.argv[2] == "get"
        and sys.argv[3] == "agent.disabled_toolsets"):
    with open(CONFIG_PATH) as fh:
        cfg = json.load(fh)
    sys.stdout.write(json.dumps(
        (cfg.get("agent") or {}).get("disabled_toolsets")) + "\\n")
    sys.exit(0)
if len(sys.argv) >= 2 and sys.argv[1] == "-z":
    with open(PID_FILE, "w") as fh:
        fh.write(str(os.getpid()) + "\\n")
    sys.stdout.write("pid-stub-started\\n")
    sys.stdout.flush()
    time.sleep(SLEEP_SEC)
    sys.stdout.write("pid-stub-done\\n")
    sys.exit(0)
sys.exit(0)
'''


def make_pid_stub(tmpdir, pid_file, sleep_sec):
    stub_path = os.path.join(tmpdir, "pid-stub.py")
    with open(stub_path, "w") as fh:
        fh.write(PID_STUB_SOURCE % {"pid_file": pid_file,
                                    "sleep_sec": sleep_sec})
    os.chmod(stub_path, os.stat(stub_path).st_mode | stat.S_IEXEC)
    install_fake_venv_python(tmpdir)
    return stub_path


def wait_for_pid_file(path, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            with open(path) as fh:
                raw = fh.read().strip()
            if raw and raw[0].isdigit():
                return int(raw)
        time.sleep(0.05)
    return None


def process_is_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class HermesDelegateCancelProgressTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.control_file = os.path.join(self.tmpdir, "control.json")
        write_control(self.control_file)
        self.stub = make_stub(self.tmpdir, self.control_file)
        self.env_backup = dict(os.environ)
        os.environ["HERMES_BIN"] = self.stub
        os.environ[MOD.TEMPLATE_HOME_VAR] = \
            make_template_home(self.tmpdir)
        os.environ[MOD.LOCK_DIR_VAR] = os.path.join(self.tmpdir, "locks")
        os.environ[MOD.RUNS_DIR_VAR] = os.path.join(self.tmpdir, "runs")
        os.environ[MOD.PROVIDER_VAR] = "local"
        os.environ[MOD.BASE_URL_VAR] = "http://127.0.0.1:11434"
        for name in (MOD.MODEL_VAR, MOD.CONSOLE_PROVIDER_VAR,
                     MOD.CONSOLE_BASE_URL_VAR, MOD.CONSOLE_MODEL_VAR,
                     "CBOX_OLLAMA_CONTEXT_LENGTH", MOD.TIMEOUT_VAR,
                     MOD.IDLE_TIMEOUT_VAR, MOD.MAX_PROMPT_VAR,
                     MOD.MAX_RESPONSE_VAR, MOD.DEPTH_VAR,
                     MOD.LEGACY_DEPTH_VAR, MOD.CONCURRENCY_VAR,
                     "OLLAMA_NUM_PARALLEL", MOD.QUEUE_WAIT_VAR):
            os.environ.pop(name, None)
        os.environ[MOD.AUDIT_VAR] = os.path.join(self.tmpdir, "audit.jsonl")
        for reset in (lambda: MOD._CANCEL.clear(),
                      lambda: MOD._CLOSED.clear(),
                      MOD.end_call,
                      lambda: MOD._SHUTDOWN.__setitem__(0, False),
                      lambda: MOD._LIVE_PROC.__setitem__(0, None),
                      lambda: MOD._LIVE_HOME.__setitem__(0, None),
                      lambda: MOD._CANCELLED_IDS.clear()):
            try:
                reset()
            except AttributeError:
                pass

    def tearDown(self):
        for reset in (lambda: MOD._CANCEL.clear(),
                      lambda: MOD._CLOSED.clear(),
                      MOD.end_call,
                      lambda: MOD._SHUTDOWN.__setitem__(0, False),
                      lambda: MOD._LIVE_PROC.__setitem__(0, None),
                      lambda: MOD._LIVE_HOME.__setitem__(0, None),
                      lambda: MOD._CANCELLED_IDS.clear()):
            try:
                reset()
            except AttributeError:
                pass
        os.environ.clear()
        os.environ.update(self.env_backup)

    def _pid_stub(self, tag, sleep_sec):
        pid_file = os.path.join(self.tmpdir, "pid_%s.txt" % tag)
        stub_path = make_pid_stub(self.tmpdir, pid_file, sleep_sec)
        os.environ["HERMES_BIN"] = stub_path
        return pid_file

    def _heartbeat_stub(self, beats, beat_gap_sec):
        write_control(self.control_file, mode="heartbeat", beats=beats,
                      beat_gap_sec=beat_gap_sec)
        os.environ["HERMES_BIN"] = self.stub

    def test_progress_notifies_while_running(self):
        self._heartbeat_stub(beats=8, beat_gap_sec=0.3)
        recorded = []
        with mock.patch.object(
                MOD, "send", side_effect=lambda m: recorded.append(m)), \
                mock.patch.object(MOD, "PROGRESS_MIN_GAP_SEC", 0), \
                mock.patch.object(MOD, "HEARTBEAT_POLL_SEC", 0.1):
            self.assertTrue(MOD.begin_call(7, "tok"))
            text, err, meta = MOD.spawn_hermes("hi", None)
        MOD.end_call()
        self.assertIsNone(err, (text, err))
        self.assertIn("stub-heartbeat-answer", text)
        pings = [
            m for m in recorded
            if m.get("method") == "notifications/progress"
        ]
        self.assertGreaterEqual(len(pings), 2, recorded)
        for m in pings:
            self.assertEqual(m["params"]["progressToken"], "tok")
        seqs = [m["params"]["progress"] for m in pings]
        for earlier, later in zip(seqs, seqs[1:]):
            self.assertLess(earlier, later, seqs)

    def test_no_progress_token_sends_nothing(self):
        self._heartbeat_stub(beats=8, beat_gap_sec=0.3)
        recorded = []
        with mock.patch.object(
                MOD, "send", side_effect=lambda m: recorded.append(m)), \
                mock.patch.object(MOD, "PROGRESS_MIN_GAP_SEC", 0), \
                mock.patch.object(MOD, "HEARTBEAT_POLL_SEC", 0.1):
            self.assertTrue(MOD.begin_call(8, None))
            text, err, meta = MOD.spawn_hermes("hi", None)
        MOD.end_call()
        self.assertIsNone(err, (text, err))
        self.assertIn("stub-heartbeat-answer", text)
        pings = [
            m for m in recorded
            if m.get("method") == "notifications/progress"
        ]
        self.assertEqual(pings, [], recorded)

    def test_cancel_kills_the_hermes_child(self):
        pid_file = self._pid_stub("kill", 60)
        outcome = {}

        def runner():
            outcome["result"] = MOD.spawn_hermes("hi", None)

        self.assertTrue(MOD.begin_call(9, None))
        thread = threading.Thread(target=runner, daemon=True)
        thread.start()
        pid = wait_for_pid_file(pid_file, 5)
        self.assertIsNotNone(pid, "the stub never recorded its pid")
        time.sleep(0.3)
        MOD.cancel_request(9)
        thread.join(timeout=10)
        self.assertFalse(
            thread.is_alive(), "spawn_hermes did not exit after cancel")
        text, err, meta = outcome["result"]
        self.assertIsNone(text)
        self.assertEqual(err, MOD.CANCELLED_MESSAGE)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not process_is_alive(pid):
                break
            time.sleep(0.1)
        self.assertFalse(
            process_is_alive(pid),
            "hermes child %d is still alive after cancel" % pid)

    def test_cancel_before_begin_refuses_that_call_only(self):
        MOD.cancel_request(10)
        self.assertFalse(MOD.begin_call(10, None))
        self.assertTrue(MOD.begin_call(11, None))
        self.assertFalse(MOD.cancelled())
        MOD.end_call()

    def test_stdio_cancel_suppresses_the_reply(self):
        pid_file = self._pid_stub("stdio", 60)
        env = dict(os.environ)
        script = str(ROOT / "etc" / "mcp" / "hermes_delegate_mcp.py")
        proc = subprocess.Popen(
            [sys.executable, script],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env)
        out_chunks = []
        err_chunks = []

        def pump(fh, sink):
            sink.append(fh.read())
            fh.close()

        out_thread = threading.Thread(
            target=pump, args=(proc.stdout, out_chunks), daemon=True)
        err_thread = threading.Thread(
            target=pump, args=(proc.stderr, err_chunks), daemon=True)
        out_thread.start()
        err_thread.start()
        try:
            def write_msg(msg):
                proc.stdin.write((json.dumps(msg) + "\n").encode())
                proc.stdin.flush()

            write_msg(
                {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": "2024-11-05"}})
            time.sleep(0.4)
            write_msg(
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                 "params": {"name": "hermes-delegate",
                            "arguments": {"prompt": "hi"},
                            "_meta": {"progressToken": "p1"}}})
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if os.path.exists(pid_file):
                    break
                time.sleep(0.05)
            self.assertTrue(
                os.path.exists(pid_file),
                "the long-sleeping stub never started")
            time.sleep(0.5)
            write_msg(
                {"jsonrpc": "2.0", "method": "notifications/cancelled",
                 "params": {"requestId": 2}})
            time.sleep(0.3)
            write_msg({"jsonrpc": "2.0", "id": 3, "method": "ping"})
            proc.stdin.close()
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass
            raise
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and proc.poll() is None:
            time.sleep(0.05)
        self.assertIsNotNone(
            proc.poll(), "server did not exit within 15s after cancel")
        self.assertEqual(proc.returncode, 0, b"".join(err_chunks).decode())
        out_thread.join(timeout=5)
        out = b"".join(out_chunks).decode()
        lines = [l for l in out.splitlines() if l.strip()]
        messages = [json.loads(l) for l in lines]
        by_id = {m["id"]: m for m in messages if m.get("id") is not None}
        self.assertIn(1, by_id)
        self.assertIn(3, by_id)
        self.assertNotIn(2, by_id,
                         "a cancelled call must not be replied to")
        pings = [
            m for m in messages
            if m.get("method") == "notifications/progress"
            and m.get("params", {}).get("progressToken") == "p1"
        ]
        self.assertGreaterEqual(len(pings), 1, messages)
        with open(pid_file) as fh:
            pid = int(fh.read().strip())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not process_is_alive(pid):
                break
            time.sleep(0.1)
        self.assertFalse(
            process_is_alive(pid),
            "the stub pid %d survived a client cancellation" % pid)

    def test_eof_alone_does_not_cancel_a_piped_call(self):
        write_control(self.control_file)
        os.environ["HERMES_BIN"] = self.stub
        env = dict(os.environ)
        script = str(ROOT / "etc" / "mcp" / "hermes_delegate_mcp.py")
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2024-11-05"}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "hermes-delegate",
                        "arguments": {"prompt": "hello"}}},
        ]
        payload = "".join(json.dumps(m) + "\n" for m in messages).encode()
        proc = subprocess.run(
            [sys.executable, script], input=payload,
            capture_output=True, env=env, timeout=15)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        replies = [
            json.loads(l)
            for l in proc.stdout.decode().splitlines() if l.strip()
        ]
        by_id = {m["id"]: m for m in replies if m.get("id") is not None}
        self.assertIn(2, by_id, replies)
        self.assertFalse(by_id[2]["result"]["isError"])
        self.assertIn(
            "stub-canned-answer", by_id[2]["result"]["content"][0]["text"])

    def test_cancel_request_ignores_invalid_ids_and_begin_call_accepts_any(self):
        for bad in ({}, [], True):
            MOD.cancel_request(bad)
            self.assertEqual(len(MOD._CANCELLED_IDS), 0,
                             "cancel_request(%r) must be ignored" % (bad,))
        self.assertTrue(MOD.begin_call([], None))
        MOD.end_call()

    def test_cancelled_ids_ring_caps_at_256_dropping_oldest(self):
        for i in range(1, 301):
            MOD.cancel_request(i)
        self.assertEqual(len(MOD._CANCELLED_IDS), MOD.CANCEL_MEMORY)
        self.assertFalse(MOD.begin_call(300, None))
        MOD.end_call()
        self.assertTrue(MOD.begin_call(1, None))
        MOD.end_call()

    def _stdio_server(self):
        env = dict(os.environ)
        script = str(ROOT / "etc" / "mcp" / "hermes_delegate_mcp.py")
        proc = subprocess.Popen(
            [sys.executable, script],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env)
        out_chunks = []
        err_chunks = []

        def pump(fh, sink):
            sink.append(fh.read())
            fh.close()

        out_thread = threading.Thread(
            target=pump, args=(proc.stdout, out_chunks), daemon=True)
        err_thread = threading.Thread(
            target=pump, args=(proc.stderr, err_chunks), daemon=True)
        out_thread.start()
        err_thread.start()
        return proc, out_thread, out_chunks, err_chunks

    def _read_messages(self, out_chunks):
        out = b"".join(out_chunks).decode("utf-8", "replace")
        lines = [l for l in out.splitlines() if l.strip()]
        return [json.loads(l) for l in lines]

    def test_stdio_cancelled_with_dict_request_id_keeps_serving(self):
        write_control(self.control_file)
        os.environ["HERMES_BIN"] = self.stub
        proc, out_thread, out_chunks, _ = self._stdio_server()
        try:
            def write_msg(msg):
                proc.stdin.write((json.dumps(msg) + "\n").encode())
                proc.stdin.flush()

            write_msg(
                {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": "2024-11-05"}})
            write_msg(
                {"jsonrpc": "2.0",
                 "method": "notifications/cancelled",
                 "params": {"requestId": {}}})
            write_msg(
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                 "params": {"name": "hermes-delegate",
                            "arguments": {"prompt": "hi"}}})
            write_msg({"jsonrpc": "2.0", "id": 3, "method": "ping"})
            proc.stdin.close()
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass
            raise
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and proc.poll() is None:
            time.sleep(0.05)
        self.assertIsNotNone(proc.poll(),
                             "server did not exit within 15s")
        out_thread.join(timeout=5)
        messages = self._read_messages(out_chunks)
        by_id = {m["id"]: m for m in messages if "id" in m}
        self.assertIn(2, by_id,
                      "a tools/call after a dict requestId must be answered")
        self.assertIn("stub-canned-answer",
                      by_id[2]["result"]["content"][0]["text"])
        self.assertIn(3, by_id, "server must still serve a ping after")

    def test_stdio_tools_call_without_id_is_ignored_and_never_spawned(self):
        marker = os.path.join(self.tmpdir, "marker_no_id.txt")
        write_control(self.control_file, marker=marker)
        os.environ["HERMES_BIN"] = self.stub
        proc, out_thread, out_chunks, _ = self._stdio_server()
        try:
            def write_msg(msg):
                proc.stdin.write((json.dumps(msg) + "\n").encode())
                proc.stdin.flush()

            write_msg(
                {"jsonrpc": "2.0", "method": "tools/call",
                 "params": {"name": "hermes-delegate",
                            "arguments": {"prompt": "hi"}}})
            write_msg({"jsonrpc": "2.0", "id": 5, "method": "ping"})
            proc.stdin.close()
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass
            raise
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and proc.poll() is None:
            time.sleep(0.05)
        self.assertIsNotNone(proc.poll(),
                             "server did not exit within 15s")
        out_thread.join(timeout=5)
        messages = self._read_messages(out_chunks)
        by_id = {m["id"]: m for m in messages if "id" in m}
        self.assertIn(5, by_id, "the ping must be answered")
        for m in messages:
            self.assertNotIn("hermes-delegate",
                             json.dumps(m.get("result", {})),
                             "a tools/call without an id must not be run: %r"
                             % (m,))
        self.assertFalse(os.path.exists(marker),
                         "the stub must never be spawned for an id-less "
                         "tools/call")

    def test_stdio_progress_token_over_max_len_is_treated_as_absent(self):
        write_control(self.control_file, mode="heartbeat", beats=4,
                      beat_gap_sec=0.3)
        os.environ["HERMES_BIN"] = self.stub
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "60"
        os.environ["CBOX_HERMES_DELEGATE_IDLE_TIMEOUT_SEC"] = "2"
        proc, out_thread, out_chunks, _ = self._stdio_server()
        try:
            def write_msg(msg):
                proc.stdin.write((json.dumps(msg) + "\n").encode())
                proc.stdin.flush()

            write_msg(
                {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": "2024-11-05"}})
            write_msg(
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                 "params": {"name": "hermes-delegate",
                            "arguments": {"prompt": "hi"},
                            "_meta": {"progressToken": "x" * 300}}})
            write_msg({"jsonrpc": "2.0", "id": 3, "method": "ping"})
            proc.stdin.close()
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass
            raise
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and proc.poll() is None:
            time.sleep(0.05)
        self.assertIsNotNone(proc.poll(),
                             "server did not exit within 15s")
        out_thread.join(timeout=5)
        messages = self._read_messages(out_chunks)
        by_id = {m["id"]: m for m in messages if "id" in m}
        self.assertIn(2, by_id, messages)
        self.assertIn("stub-heartbeat-answer",
                      by_id[2]["result"]["content"][0]["text"])
        pings = [
            m for m in messages
            if m.get("method") == "notifications/progress"
        ]
        self.assertEqual(pings, [],
                         "no progress may be sent for a token longer than "
                         "%d chars: %r" % (MOD.MAX_TOKEN_LEN, pings))

    def test_stdio_sigterm_kills_the_live_hermes_process_group(self):
        pid_file = self._pid_stub("sigterm", 60)
        proc, out_thread, out_chunks, _ = self._stdio_server()
        try:
            def write_msg(msg):
                proc.stdin.write((json.dumps(msg) + "\n").encode())
                proc.stdin.flush()

            write_msg(
                {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": "2024-11-05"}})
            write_msg(
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                 "params": {"name": "hermes-delegate",
                            "arguments": {"prompt": "hi"}}})
            pid = wait_for_pid_file(pid_file, 5)
            self.assertIsNotNone(pid, "the long-sleeping stub never started")
            proc.send_signal(signal.SIGTERM)
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass
            raise
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and proc.poll() is None:
            time.sleep(0.05)
        self.assertIsNotNone(proc.poll(),
                             "server did not exit within 10s of SIGTERM")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not process_is_alive(pid):
                break
            time.sleep(0.1)
        self.assertFalse(process_is_alive(pid),
                         "stub pid %d survived the SIGTERM" % pid)
        out_thread.join(timeout=5)

    def test_stdio_oversized_line_gets_error_and_server_keeps_serving(self):
        write_control(self.control_file)
        os.environ["HERMES_BIN"] = self.stub
        proc, out_thread, out_chunks, _ = self._stdio_server()
        try:
            long_line = b"{" + b"a" * (4 * 1024 * 1024 + 98) + b"\n"
            proc.stdin.write(long_line)
            proc.stdin.write(
                (json.dumps({"jsonrpc": "2.0", "id": 9, "method": "ping"})
                 + "\n").encode())
            proc.stdin.flush()
            proc.stdin.close()
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass
            raise
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and proc.poll() is None:
            time.sleep(0.05)
        self.assertIsNotNone(proc.poll(),
                             "server did not exit within 15s")
        out_thread.join(timeout=5)
        messages = self._read_messages(out_chunks)
        by_id = {m["id"]: m for m in messages if "id" in m}
        self.assertIn(9, by_id,
                      "the ping after the oversized line must be answered")
        too_long = [
            m for m in messages
            if isinstance(m.get("error"), dict)
            and m["error"].get("message") == "request line too long"
        ]
        self.assertTrue(
            too_long, "expected a -32600 'request line too long' error: %r"
            % (messages,))
        self.assertEqual(too_long[0]["error"]["code"], -32600)

    def test_output_log_present_on_timeout(self):
        write_control(self.control_file, mode="sleep_with_output",
                      sleep_sec=10)
        os.environ["HERMES_BIN"] = self.stub
        os.environ[MOD.TIMEOUT_VAR] = "1"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        text = result["content"][0]["text"]
        self.assertIn("timed out", text)
        m = re.search(r"run id: (\S+)", text)
        self.assertIsNotNone(m, text)
        run_id = m.group(1)
        log_path = os.path.join(
            os.environ[MOD.RUNS_DIR_VAR], run_id, "output.log")
        deadline = time.monotonic() + 5
        content = b""
        while time.monotonic() < deadline:
            if os.path.isfile(log_path):
                with open(log_path, "rb") as fh:
                    content = fh.read()
                if content:
                    break
            time.sleep(0.1)
        self.assertIn(b"[out] sleep-with-output-started", content)

    def test_output_log_present_on_cancel(self):
        pid_file = self._pid_stub("cancel-log", 60)
        outcome = {}

        def runner():
            outcome["result"] = MOD.spawn_hermes("hi", None)

        self.assertTrue(MOD.begin_call(20, None))
        thread = threading.Thread(target=runner, daemon=True)
        thread.start()
        pid = wait_for_pid_file(pid_file, 5)
        self.assertIsNotNone(pid, "the stub never recorded its pid")
        time.sleep(0.3)
        MOD.cancel_request(20)
        thread.join(timeout=10)
        MOD.end_call()
        text, err, meta = outcome["result"]
        self.assertEqual(err, MOD.CANCELLED_MESSAGE)
        run_id = meta.get("run_id")
        self.assertIsNotNone(run_id)
        log_path = os.path.join(
            os.environ[MOD.RUNS_DIR_VAR], run_id, "output.log")
        self.assertTrue(os.path.isfile(log_path))
        with open(log_path, "rb") as fh:
            content = fh.read()
        self.assertIn(b"[out] pid-stub-started", content)

    def test_cancelled_run_saved_with_outcome_and_audit_carries_run_id(self):
        pid_file = self._pid_stub("cancel-audit", 60)
        outcome = {}

        def runner():
            outcome["result"] = MOD.run_hermes_delegate({"prompt": "hi"})

        self.assertTrue(MOD.begin_call(21, None))
        thread = threading.Thread(target=runner, daemon=True)
        thread.start()
        pid = wait_for_pid_file(pid_file, 5)
        self.assertIsNotNone(pid, "the stub never recorded its pid")
        time.sleep(0.3)
        MOD.cancel_request(21)
        thread.join(timeout=10)
        MOD.end_call()
        result = outcome["result"]
        self.assertTrue(result["isError"])
        self.assertIn("cancelled", result["content"][0]["text"])
        with open(os.environ[MOD.AUDIT_VAR]) as fh:
            recs = [json.loads(l) for l in fh if l.strip()]
        cancelled_recs = [r for r in recs if r.get("outcome") == "cancelled"]
        self.assertTrue(cancelled_recs, recs)
        run_id = cancelled_recs[-1]["run_id"]
        self.assertIsNotNone(run_id)
        run_dir = os.path.join(os.environ[MOD.RUNS_DIR_VAR], run_id)
        self.assertTrue(os.path.isdir(run_dir))
        with open(os.path.join(run_dir, "summary.json")) as fh:
            summary = json.load(fh)
        self.assertEqual(summary["outcome"], "cancelled")


class SweepHermesHomeTests(unittest.TestCase):
    GRANDCHILD_SCRIPT = (
        "import os, sys, time\n"
        "with open(sys.argv[1], 'w') as fh:\n"
        "    fh.write(str(os.getpid()))\n"
        "    fh.flush()\n"
        "time.sleep(30)\n"
    )

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _spawn(self, script, pid_file, hermes_home):
        env = dict(os.environ)
        if hermes_home is None:
            env.pop("HERMES_HOME", None)
        else:
            env["HERMES_HOME"] = hermes_home
        return subprocess.Popen(
            [sys.executable, script, pid_file], env=env,
            start_new_session=True)

    def test_sweep_kills_matching_process_and_spares_unrelated_one(self):
        home = os.path.join(self.tmpdir, "eph-home")
        os.makedirs(home)
        other_home = os.path.join(self.tmpdir, "eph-home-other")
        os.makedirs(other_home)
        script = os.path.join(self.tmpdir, "grandchild.py")
        with open(script, "w") as fh:
            fh.write(self.GRANDCHILD_SCRIPT)
        pid_file_match = os.path.join(self.tmpdir, "match.pid")
        pid_file_other = os.path.join(self.tmpdir, "other.pid")
        proc_match = self._spawn(script, pid_file_match, home)
        proc_other = self._spawn(script, pid_file_other, other_home)
        try:
            pid_match = wait_for_pid_file(pid_file_match, 5)
            pid_other = wait_for_pid_file(pid_file_other, 5)
            self.assertIsNotNone(pid_match)
            self.assertIsNotNone(pid_other)
            MOD._sweep_hermes_home(home, grace_sec=1)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline \
                    and proc_match.poll() is None:
                time.sleep(0.1)
            self.assertIsNotNone(
                proc_match.poll(),
                "matching process survived the sweep")
            self.assertIsNone(
                proc_other.poll(),
                "unrelated process was killed by the sweep")
        finally:
            for p in (proc_match, proc_other):
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                try:
                    p.wait(timeout=5)
                except Exception:
                    pass

    def test_sweep_with_no_hermes_home_is_a_noop(self):
        MOD._sweep_hermes_home(None)
        MOD._sweep_hermes_home("")


class PidfdSignalTests(unittest.TestCase):
    def test_pidfd_open_returns_none_for_an_invalid_pid(self):
        self.assertIsNone(MOD._pidfd_open(-1))

    def test_signal_target_falls_back_to_kill_when_no_pidfd(self):
        with mock.patch("os.kill") as m_kill:
            MOD._signal_target(999999, None, signal.SIGTERM)
        m_kill.assert_called_once_with(999999, signal.SIGTERM)

    def test_signal_target_uses_pidfd_send_signal_when_pidfd_is_given(self):
        with mock.patch.object(
                MOD.signal, "pidfd_send_signal", create=True) as m_send, \
                mock.patch("os.kill") as m_kill:
            MOD._signal_target(999999, 7, signal.SIGTERM)
        m_send.assert_called_once_with(7, signal.SIGTERM, None, 0)
        m_kill.assert_not_called()

    def test_target_alive_falls_back_to_pid_alive_when_no_pidfd(self):
        with mock.patch.object(MOD, "_pid_alive", return_value=True) as m_alive:
            self.assertTrue(MOD._target_alive(999999, None))
        m_alive.assert_called_once_with(999999)


if __name__ == "__main__":
    unittest.main()
