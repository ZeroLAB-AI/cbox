#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "ask_claude_mcp", ROOT / "etc" / "codex" / "ask_claude_mcp.py"
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


def _reset_state():
    MOD._CANCEL.clear()
    MOD._CLOSED.clear()
    MOD.end_call()
    MOD._SHUTDOWN[0] = False
    MOD._IN_CALL[0] = False
    MOD._LIVE_PROC[0] = None
    MOD._CANCELLED_IDS.clear()


STUB_SOURCE = '''
import json
import os
import subprocess
import sys
import time

PID_FILE = %(pid_file)r
GRANDCHILD_PID_FILE = %(grandchild_pid_file)r
SESSION_ID = %(session_id)r
MODE = %(mode)r
SLEEP_SEC = %(sleep_sec)r

with open(PID_FILE, "w") as fh:
    fh.write(str(os.getpid()))

sys.stdout.write(json.dumps(
    {"type": "system", "subtype": "init", "session_id": SESSION_ID}) + "\\n")
sys.stdout.flush()

if MODE == "quick":
    sys.stdout.write(json.dumps(
        {"type": "result", "is_error": False, "result": "stub-ok",
         "session_id": SESSION_ID}) + "\\n")
    sys.stdout.flush()
    sys.exit(0)

if MODE == "quick_no_newline":
    sys.stdout.write(json.dumps(
        {"type": "result", "is_error": False, "result": "stub-ok-no-newline",
         "session_id": SESSION_ID}))
    sys.stdout.flush()
    sys.exit(0)

if MODE == "sleep_with_grandchild" and GRANDCHILD_PID_FILE:
    subprocess.Popen([sys.executable, "-c",
        "import os,sys,time\\n"
        "open(sys.argv[1], 'w').write(str(os.getpid()))\\n"
        "time.sleep(120)\\n", GRANDCHILD_PID_FILE])

time.sleep(SLEEP_SEC)
sys.stdout.write(json.dumps(
    {"type": "result", "is_error": False, "result": "stub-late",
     "session_id": SESSION_ID}) + "\\n")
sys.stdout.flush()
'''


def write_stub(tmpdir, mode, sleep_sec=60, session_id="sess-stub",
               pid_file=None, grandchild_pid_file=None):
    stub_path = os.path.join(tmpdir, "claude-stub-%s.py" % mode)
    pid_file = pid_file or os.path.join(tmpdir, "pid-%s.txt" % mode)
    with open(stub_path, "w") as fh:
        fh.write(STUB_SOURCE % {
            "pid_file": pid_file,
            "grandchild_pid_file": grandchild_pid_file,
            "session_id": session_id,
            "mode": mode,
            "sleep_sec": sleep_sec,
        })
    os.chmod(stub_path, os.stat(stub_path).st_mode | stat.S_IEXEC)
    return stub_path, pid_file


def wait_for_file(path, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return True
        time.sleep(0.05)
    return False


def process_is_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_pid(path):
    with open(path) as fh:
        return int(fh.read().strip())


class SpawnClaudeAttemptTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.addCleanup(_reset_state)
        _reset_state()

    def test_quick_success_captures_session_id_and_result(self):
        stub, _ = write_stub(self.tmpdir, "quick")
        env = dict(os.environ)
        result = MOD.spawn_claude_attempt(
            [sys.executable, stub], self.tmpdir, env, 10)
        self.assertFalse(result.cancelled)
        self.assertFalse(result.timed_out)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.session_id, "sess-stub")
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["result"], "stub-ok")

    def test_timeout_returns_session_id_and_partial_output(self):
        stub, pid_file = write_stub(self.tmpdir, "sleep_with_grandchild",
                                     sleep_sec=60)
        env = dict(os.environ)
        result = MOD.spawn_claude_attempt(
            [sys.executable, stub], self.tmpdir, env, 0.5)
        self.assertTrue(result.timed_out)
        self.assertFalse(result.cancelled)
        self.assertEqual(result.session_id, "sess-stub")
        self.assertIn("sess-stub", result.partial_text)
        self.assertTrue(wait_for_file(pid_file, 5))
        pid = read_pid(pid_file)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and process_is_alive(pid):
            time.sleep(0.1)
        self.assertFalse(process_is_alive(pid),
                         "the stub survived its own timeout kill")

    def test_cancel_kills_stub_and_setsid_grandchild_via_the_group(self):
        grandchild_pid_file = os.path.join(self.tmpdir, "grandchild.pid")
        stub, pid_file = write_stub(
            self.tmpdir, "sleep_with_grandchild", sleep_sec=120,
            grandchild_pid_file=grandchild_pid_file)
        env = dict(os.environ)
        outcome = {}

        def runner():
            outcome["result"] = MOD.spawn_claude_attempt(
                [sys.executable, stub], self.tmpdir, env, 30)

        self.assertTrue(MOD.begin_call(101, None))
        thread = threading.Thread(target=runner, daemon=True)
        thread.start()
        self.assertTrue(wait_for_file(pid_file, 5),
                        "the stub never recorded its pid")
        self.assertTrue(wait_for_file(grandchild_pid_file, 5),
                        "the grandchild never recorded its pid")
        stub_pid = read_pid(pid_file)
        grandchild_pid = read_pid(grandchild_pid_file)
        MOD.cancel_request(101)
        thread.join(timeout=10)
        MOD.end_call()
        self.assertFalse(thread.is_alive(),
                         "spawn_claude_attempt did not exit after cancel")
        result = outcome["result"]
        self.assertTrue(result.cancelled)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and (
                process_is_alive(stub_pid) or process_is_alive(grandchild_pid)):
            time.sleep(0.1)
        self.assertFalse(process_is_alive(stub_pid),
                         "the claude stub is still alive after cancel")
        self.assertFalse(process_is_alive(grandchild_pid),
                         "the grandchild is still alive after cancel - the "
                         "group kill did not reach it")

    def test_progress_heartbeat_with_short_override(self):
        stub, _ = write_stub(self.tmpdir, "sleep_with_grandchild",
                              sleep_sec=1.2)
        env = dict(os.environ)
        recorded = []
        with mock.patch.object(
                MOD, "send", side_effect=lambda m: recorded.append(m)), \
                mock.patch.dict(
                    os.environ, {MOD.PROGRESS_INTERVAL_ENV: "0.2"}):
            self.assertTrue(MOD.begin_call(102, "tok-1"))
            MOD.spawn_claude_attempt([sys.executable, stub], self.tmpdir,
                                     env, 10)
        MOD.end_call()
        pings = [m for m in recorded
                 if m.get("method") == "notifications/progress"]
        self.assertGreaterEqual(len(pings), 2, recorded)
        for m in pings:
            self.assertEqual(m["params"]["progressToken"], "tok-1")
        seqs = [m["params"]["progress"] for m in pings]
        for earlier, later in zip(seqs, seqs[1:]):
            self.assertLess(earlier, later, seqs)

    def test_setpriv_prefixes_argv_when_available(self):
        captured = {}

        class FakeProc:
            def __init__(self):
                self.pid = os.getpid()
                self.stdout = os.fdopen(os.open(os.devnull, os.O_RDONLY), "rb")
                self.stderr = os.fdopen(os.open(os.devnull, os.O_RDONLY), "rb")

            def wait(self, timeout=None):
                return 0

            def poll(self):
                return 0

        def fake_popen(argv, **kwargs):
            captured["argv"] = list(argv)
            return FakeProc()

        with mock.patch.object(MOD.shutil, "which",
                               lambda name: "/usr/bin/setpriv"
                               if name == "setpriv" else None), \
                mock.patch.object(MOD.subprocess, "Popen", fake_popen):
            MOD.spawn_claude_attempt(["claude", "-p", "hi"], "/tmp",
                                     dict(os.environ), 5)
        argv = captured["argv"]
        self.assertEqual(argv[:3], ["/usr/bin/setpriv", "--pdeathsig", "KILL"])
        self.assertEqual(argv[3:], ["claude", "-p", "hi"])

    def test_no_setpriv_leaves_argv_unprefixed(self):
        captured = {}

        class FakeProc:
            def __init__(self):
                self.pid = os.getpid()
                self.stdout = os.fdopen(os.open(os.devnull, os.O_RDONLY), "rb")
                self.stderr = os.fdopen(os.open(os.devnull, os.O_RDONLY), "rb")

            def wait(self, timeout=None):
                return 0

            def poll(self):
                return 0

        def fake_popen(argv, **kwargs):
            captured["argv"] = list(argv)
            return FakeProc()

        with mock.patch.object(MOD.shutil, "which", lambda name: None), \
                mock.patch.object(MOD.subprocess, "Popen", fake_popen):
            MOD.spawn_claude_attempt(["claude", "-p", "hi"], "/tmp",
                                     dict(os.environ), 5)
        self.assertEqual(captured["argv"], ["claude", "-p", "hi"])

    def test_final_line_without_trailing_newline_is_still_captured(self):
        stub, _ = write_stub(self.tmpdir, "quick_no_newline")
        env = dict(os.environ)
        result = MOD.spawn_claude_attempt(
            [sys.executable, stub], self.tmpdir, env, 10)
        self.assertFalse(result.cancelled)
        self.assertFalse(result.timed_out)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.session_id, "sess-stub")
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["result"], "stub-ok-no-newline")

    def test_select_wait_floored_at_50ms_with_tiny_progress_interval(self):
        stub, _ = write_stub(self.tmpdir, "quick")
        env = dict(os.environ)
        waits = []
        real_select = MOD.select.select

        def spy_select(rlist, wlist, xlist, timeout):
            waits.append(timeout)
            return real_select(rlist, wlist, xlist, timeout)

        with mock.patch.object(MOD.select, "select", spy_select), \
                mock.patch.dict(
                    os.environ, {MOD.PROGRESS_INTERVAL_ENV: "0.0001"}):
            MOD.spawn_claude_attempt(
                [sys.executable, stub], self.tmpdir, env, 10)
        self.assertTrue(waits)
        for wait in waits:
            self.assertGreaterEqual(wait, 0.05, waits)


class RunClaudeCancelAndTimeoutBudgetTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(_reset_state)
        _reset_state()
        os.environ.pop(MOD.DEPTH_VAR, None)
        os.environ.pop(MOD.LEGACY_DEPTH_VAR, None)

    def test_cancel_reply_carries_session_id(self):
        proc = types.SimpleNamespace(
            returncode=None, stdout="", stderr="",
            session_id="sess-cancel", cancelled=True, timed_out=False,
            partial_text="")
        with mock.patch.object(MOD, "spawn_claude_attempt",
                               lambda *a, **k: proc):
            result = MOD.run_claude({"prompt": "hi"})
        self.assertTrue(result["isError"])
        self.assertIn("sess-cancel", result["content"][0]["text"])

    def test_zero_timeout_env_returns_clean_error_without_spawning(self):
        spec = importlib.util.spec_from_file_location(
            "ask_claude_mcp_zero_timeout",
            ROOT / "etc" / "codex" / "ask_claude_mcp.py")
        mod = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, {"ASK_CLAUDE_TIMEOUT": "0"}):
            spec.loader.exec_module(mod)
        self.assertEqual(mod.CALL_TIMEOUT, 0)
        called = {"n": 0}

        def fake_spawn(*a, **k):
            called["n"] += 1
            return None

        with mock.patch.object(mod, "spawn_claude_attempt", fake_spawn):
            result = mod.run_claude({"prompt": "hi"})
        self.assertEqual(called["n"], 0)
        self.assertTrue(result["isError"])
        self.assertIn("timeout expired before any attempt could run",
                      result["content"][0]["text"])


class OnSignalTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.addCleanup(_reset_state)
        _reset_state()

    def test_sigterm_kills_the_live_process_group_mid_call(self):
        pid_file = os.path.join(self.tmpdir, "pid.txt")
        script = os.path.join(self.tmpdir, "sleeper.py")
        with open(script, "w") as fh:
            fh.write(
                "import os, sys, time\n"
                "open(sys.argv[1], 'w').write(str(os.getpid()))\n"
                "time.sleep(60)\n")
        proc = subprocess.Popen(
            [sys.executable, script, pid_file], start_new_session=True)
        try:
            self.assertTrue(wait_for_file(pid_file, 5))
            MOD._LIVE_PROC[0] = proc
            MOD._IN_CALL[0] = True
            MOD._on_signal(signal.SIGTERM, None)
            self.assertTrue(MOD._SHUTDOWN[0])
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and proc.poll() is None:
                time.sleep(0.1)
            self.assertIsNotNone(proc.poll(),
                                 "SIGTERM handler did not kill the live proc")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)

    def test_sigterm_raises_when_not_in_call(self):
        MOD._IN_CALL[0] = False
        with self.assertRaises(SystemExit):
            MOD._on_signal(signal.SIGTERM, None)


def _write_claude_stub_on_path(bindir, source):
    path = os.path.join(bindir, "claude")
    with open(path, "w") as fh:
        fh.write(source)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
    return path


SLEEP_CLAUDE_SOURCE = '''#!/usr/bin/env python3
import json
import os
import sys
import time

PID_FILE = %(pid_file)r

with open(PID_FILE, "w") as fh:
    fh.write(str(os.getpid()))
sys.stdout.write(json.dumps(
    {"type": "system", "subtype": "init", "session_id": "sess-e2e"}) + "\\n")
sys.stdout.flush()
time.sleep(60)
'''


class StdioServerTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.bindir = os.path.join(self.tmpdir, "bin")
        os.makedirs(self.bindir)
        self.pid_file = os.path.join(self.tmpdir, "claude.pid")
        _write_claude_stub_on_path(
            self.bindir, SLEEP_CLAUDE_SOURCE % {"pid_file": self.pid_file})
        self.env = dict(os.environ)
        self.env["PATH"] = self.bindir + os.pathsep + self.env.get("PATH", "")
        self.env.pop(MOD.DEPTH_VAR, None)
        self.env.pop(MOD.LEGACY_DEPTH_VAR, None)
        self.env["ASK_CLAUDE_AUDIT"] = os.path.join(self.tmpdir, "audit.jsonl")
        self.script = str(ROOT / "etc" / "codex" / "ask_claude_mcp.py")

    def _spawn(self):
        proc = subprocess.Popen(
            [sys.executable, self.script],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=self.env)
        out_chunks, err_chunks = [], []

        def pump(fh, sink):
            sink.append(fh.read())
            fh.close()

        out_thread = threading.Thread(
            target=pump, args=(proc.stdout, out_chunks), daemon=True)
        err_thread = threading.Thread(
            target=pump, args=(proc.stderr, err_chunks), daemon=True)
        out_thread.start()
        err_thread.start()
        return proc, out_chunks, err_chunks, out_thread, err_thread

    def _write(self, proc, msg):
        proc.stdin.write((json.dumps(msg) + "\n").encode())
        proc.stdin.flush()

    def test_ping_answered_during_a_running_call(self):
        proc, out_chunks, err_chunks, out_thread, err_thread = self._spawn()
        try:
            self._write(proc, {"jsonrpc": "2.0", "id": 1,
                               "method": "initialize",
                               "params": {"protocolVersion": "2024-11-05"}})
            time.sleep(0.3)
            self._write(proc, {"jsonrpc": "2.0", "id": 2,
                               "method": "tools/call",
                               "params": {"name": "ask-claude",
                                          "arguments": {"prompt": "hi"}}})
            self.assertTrue(wait_for_file(self.pid_file, 5),
                            "the claude stub never started")
            self._write(proc, {"jsonrpc": "2.0", "id": 3, "method": "ping"})
            time.sleep(0.5)
            self._write(proc, {"jsonrpc": "2.0",
                               "method": "notifications/cancelled",
                               "params": {"requestId": 2}})
            proc.stdin.close()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and proc.poll() is None:
                time.sleep(0.05)
            self.assertIsNotNone(proc.poll(),
                                 "server did not exit within 15s")
        finally:
            if proc.poll() is None:
                proc.kill()
        out_thread.join(timeout=5)
        err_thread.join(timeout=5)
        self.assertEqual(proc.returncode, 0, b"".join(err_chunks).decode())
        lines = [l for l in b"".join(out_chunks).decode().splitlines()
                 if l.strip()]
        messages = [json.loads(l) for l in lines]
        by_id = {m["id"]: m for m in messages if m.get("id") is not None}
        self.assertIn(1, by_id)
        self.assertIn(3, by_id, "ping sent during a running call was not "
                                "answered")
        self.assertNotIn(2, by_id,
                         "a cancelled call must not be replied to")

    def test_sigterm_stops_the_server_and_the_claude_child(self):
        proc, out_chunks, err_chunks, out_thread, err_thread = self._spawn()
        try:
            self._write(proc, {"jsonrpc": "2.0", "id": 1,
                               "method": "initialize",
                               "params": {"protocolVersion": "2024-11-05"}})
            time.sleep(0.3)
            self._write(proc, {"jsonrpc": "2.0", "id": 2,
                               "method": "tools/call",
                               "params": {"name": "ask-claude",
                                          "arguments": {"prompt": "hi"}}})
            self.assertTrue(wait_for_file(self.pid_file, 5),
                            "the claude stub never started")
            claude_pid = read_pid(self.pid_file)
            proc.send_signal(signal.SIGTERM)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and proc.poll() is None:
                time.sleep(0.05)
            self.assertIsNotNone(proc.poll(),
                                 "server did not exit after SIGTERM")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and process_is_alive(claude_pid):
                time.sleep(0.1)
            self.assertFalse(process_is_alive(claude_pid),
                             "the claude child survived the server's SIGTERM")
        finally:
            if proc.poll() is None:
                proc.kill()
            try:
                proc.stdin.close()
            except Exception:
                pass
        out_thread.join(timeout=5)
        err_thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
