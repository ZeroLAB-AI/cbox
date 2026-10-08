#!/usr/bin/env python3
import atexit
import fcntl
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "etc" / "hooks" / "usage_statusline.py"


NETWORK_ENV_VARS = (
    "CBOX_USAGE_DIR",
    "CLAUDE_CONFIG_DIR",
    "CBOX_HERMES_DELEGATE_BASE_URL",
    "CBOX_HERMES_MODEL_URL",
    "CBOX_LOCAL_MODEL_URL",
    "CBOX_CODEX_USAGE_REFRESH",
    "CBOX_CLAUDE_USAGE_REFRESH",
    "CBOX_CLAUDE_USAGE_REFRESH_SEC",
    "CLAUDE_SECURESTORAGE_CONFIG_DIR",
    "CBOX_HERMES_DELEGATE_LOCK_DIR",
    "CBOX_HERMES_DELEGATE_RUNS_DIR",
    "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY",
    "OLLAMA_NUM_PARALLEL",
    "CBOX_PROFILE",
    "COLUMNS",
    "NO_COLOR",
)


_CFG_ROOT = tempfile.mkdtemp(prefix="statusline-cfg-")
atexit.register(shutil.rmtree, _CFG_ROOT, True)


def _make_cfg(name, doc):
    d = os.path.join(_CFG_ROOT, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, ".claude.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f)
    return d


PRESENT_CFG = _make_cfg("present", {"mcpServers": {"hermes-local": {"command": "x"}}})
ABSENT_CFG = _make_cfg("absent", {"mcpServers": {"codex-sol": {"command": "x"}}})


def run(payload_text, usage_dir, extra_env=None):
    env = {
        k: v for k, v in os.environ.items()
        if k not in NETWORK_ENV_VARS
    }
    env["CBOX_USAGE_DIR"] = usage_dir
    env["CLAUDE_CONFIG_DIR"] = PRESENT_CFG
    env["CBOX_CODEX_USAGE_REFRESH"] = "off"
    env["CBOX_CLAUDE_USAGE_REFRESH"] = "off"
    env["CBOX_HERMES_DELEGATE_LOCK_DIR"] = os.path.join(usage_dir, "hermes-locks-unused")
    env["CBOX_HERMES_DELEGATE_RUNS_DIR"] = os.path.join(usage_dir, "hermes-runs-unused")
    env["CBOX_HERMES_DELEGATE_MAX_CONCURRENCY"] = "1"
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run(
        ["python3", str(SCRIPT)],
        input=payload_text,
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    return proc


def run_id(epoch, suffix):
    t = time.gmtime(epoch)
    return time.strftime("%Y%m%dT%H%M%SZ", t) + "-%06x" % suffix


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


class UsageStatuslineTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")

    def tearDown(self):
        self._tmp.cleanup()

    def _claude_json(self):
        with open(os.path.join(self.usage_dir, "claude.json"), "r", encoding="utf-8") as f:
            return json.load(f)

    def test_valid_input_writes_file_and_prints_claude_segment(self):
        payload = json.dumps({
            "rate_limits": {
                "five_hour": {"used_percentage": 42, "resets_at": 1000000000},
                "seven_day": {"used_percentage": 21, "resets_at": 1000000000},
            },
        })
        proc = run(payload, self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        line = proc.stdout.strip()
        self.assertIn("claude: 100%", line)
        data = self._claude_json()
        self.assertEqual(data["source"], "claude")
        self.assertEqual(data["five_hour"]["used_percentage"], 42.0)
        self.assertEqual(data["seven_day"]["resets_at"], 1000000000.0)
        self.assertIn("captured_at", data)

    def test_file_permissions_are_locked_down(self):
        payload = json.dumps({
            "rate_limits": {
                "five_hour": {"used_percentage": 1, "resets_at": 1000000000},
                "seven_day": {"used_percentage": 1, "resets_at": 1000000000},
            },
        })
        proc = run(payload, self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        path = os.path.join(self.usage_dir, "claude.json")
        mode = stat.S_IMODE(os.stat(path).st_mode)
        self.assertEqual(mode, 0o600)
        dmode = stat.S_IMODE(os.stat(self.usage_dir).st_mode)
        self.assertEqual(dmode, 0o700)

    def test_missing_rate_limits_omits_claude_segment_and_skips_write(self):
        proc = run(json.dumps({}), self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: idle")
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "claude.json")))

    def test_garbage_stdin_never_crashes(self):
        proc = run("not json at all {{{", self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: idle")
        self.assertEqual(proc.stderr.strip(), "")
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "claude.json")))

    def test_empty_stdin_never_crashes(self):
        proc = run("", self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: idle")

    def test_iso_resets_at_is_accepted(self):
        payload = json.dumps({
            "rate_limits": {
                "seven_day": {"used_percentage": 10, "resets_at": "2026-10-01T00:00:00Z"},
            },
        })
        proc = run(payload, self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = self._claude_json()
        self.assertIsInstance(data["seven_day"]["resets_at"], float)

    def test_malformed_rate_limits_entry_is_tolerated(self):
        payload = json.dumps({
            "rate_limits": {"five_hour": "not-a-dict", "seven_day": None},
        })
        proc = run(payload, self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: idle")
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "claude.json")))


def start_fake_hermes(payload_obj, status=200):
    import http.server
    import threading

    body = json.dumps(payload_obj).encode("utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def find_refused_port():
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def base_payload():
    return json.dumps({
        "rate_limits": {
            "seven_day": {"used_percentage": 10, "resets_at": 1000000000},
        },
    })


class HermesCacheTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")

    def tearDown(self):
        self._tmp.cleanup()

    def _hermes_json(self):
        with open(os.path.join(self.usage_dir, "hermes.json"), "r", encoding="utf-8") as f:
            return json.load(f)

    def test_reachable_server_marks_reachable_and_model_loaded(self):
        server, thread = start_fake_hermes({"models": [{"name": "qwen"}]})
        try:
            base = "http://127.0.0.1:%d" % server.server_address[1]
            proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_HERMES_MODEL_URL": base})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = self._hermes_json()
            self.assertTrue(data["reachable"])
            self.assertTrue(data["model_loaded"])
        finally:
            server.shutdown()
            thread.join(timeout=5)

    def test_refused_port_marks_unreachable(self):
        port = find_refused_port()
        base = "http://127.0.0.1:%d" % port
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_HERMES_MODEL_URL": base})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = self._hermes_json()
        self.assertFalse(data["reachable"])

    def test_v1_suffix_is_stripped_from_base_url(self):
        server, thread = start_fake_hermes({"models": []})
        try:
            base = "http://127.0.0.1:%d/v1" % server.server_address[1]
            proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_HERMES_MODEL_URL": base})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = self._hermes_json()
            self.assertTrue(data["reachable"])
            self.assertFalse(data["model_loaded"])
        finally:
            server.shutdown()
            thread.join(timeout=5)

    def test_no_hermes_url_configured_writes_nothing(self):
        proc = run(base_payload(), self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "hermes.json")))

    def test_probe_is_skipped_within_throttle_window(self):
        os.makedirs(self.usage_dir, exist_ok=True)
        with open(os.path.join(self.usage_dir, "hermes.json"), "w", encoding="utf-8") as f:
            json.dump({"ts": time.time(), "last_probe_ts": time.time(),
                       "reachable": True, "model_loaded": True, "history": [True, True]}, f)
        port = find_refused_port()
        base = "http://127.0.0.1:%d" % port
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_HERMES_MODEL_URL": base})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = self._hermes_json()
        self.assertTrue(data["reachable"])


class ProbeDeadlineTests(unittest.TestCase):
    def test_a_hung_probe_thread_is_not_waited_on_past_the_deadline(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("usage_statusline_probe", str(SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        original = mod._probe_hermes_blocking

        def hung(base, timeout, result):
            time.sleep(30)

        mod._probe_hermes_blocking = hung
        try:
            started = time.monotonic()
            reachable, model_loaded = mod._probe_hermes("http://127.0.0.1:1", join_deadline=0.2)
            elapsed = time.monotonic() - started
        finally:
            mod._probe_hermes_blocking = original
        self.assertFalse(reachable)
        self.assertFalse(model_loaded)
        self.assertLess(elapsed, 2.0)

    def test_last_probe_ts_is_recorded_even_when_the_probe_hangs(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("usage_statusline_probe2", str(SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        def hung(base, timeout, result):
            time.sleep(30)

        mod._probe_hermes_blocking = hung
        tmp = tempfile.TemporaryDirectory()
        try:
            os.environ["CBOX_USAGE_DIR"] = tmp.name
            os.environ["CBOX_HERMES_MODEL_URL"] = "http://127.0.0.1:1"
            now = time.time()
            mod._update_hermes_cache(now)
            with open(os.path.join(tmp.name, "hermes.json"), "r", encoding="utf-8") as f:
                data = json.load(f)
            self.assertAlmostEqual(data["last_probe_ts"], now, delta=1.0)
        finally:
            os.environ.pop("CBOX_USAGE_DIR", None)
            os.environ.pop("CBOX_HERMES_MODEL_URL", None)
            tmp.cleanup()


class HermesBlockingProbeTests(unittest.TestCase):
    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "usage_statusline_blocking_probe", str(SCRIPT))
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self._patcher = mock.patch("urllib.request.build_opener")
        self.build_opener = self._patcher.start()
        self.opener = mock.Mock()
        self.build_opener.return_value = self.opener
        self.addCleanup(self._patcher.stop)

    def _cm(self, payload):
        if isinstance(payload, str):
            payload = payload.encode("utf-8")

        class _Resp:
            def read(self, n=None):
                return payload

        class _CM:
            def __enter__(self):
                return _Resp()

            def __exit__(self, *a):
                return False

        return _CM()

    def _probe(self, base="http://127.0.0.1:8999"):
        result = {"reachable": False, "model_loaded": False}
        self.mod._probe_hermes_blocking(base, 1.0, result)
        return result

    def test_api_ps_success_marks_reachable_and_model_loaded(self):
        self.opener.open.side_effect = lambda *a, **kw: self._cm(
            json.dumps({"models": [{"name": "qwen"}]}))
        result = self._probe()
        self.assertTrue(result["reachable"])
        self.assertTrue(result["model_loaded"])

    def test_api_ps_404_falls_back_to_v1_models(self):
        import urllib.error
        ps_err = urllib.error.HTTPError(
            "http://127.0.0.1:8999/api/ps", 404, "Not Found", {}, None)

        def open_side_effect(*a, **kw):
            if "v1/models" in a[0]:
                return self._cm(json.dumps({"data": [{"id": "qwen3.8-27b"}]}))
            raise ps_err

        self.opener.open.side_effect = open_side_effect
        result = self._probe()
        self.assertTrue(result["reachable"])
        self.assertTrue(result["model_loaded"])

    def test_api_ps_404_and_v1_models_failure_leaves_reachable_false(self):
        import urllib.error
        ps_err = urllib.error.HTTPError(
            "http://127.0.0.1:8999/api/ps", 404, "Not Found", {}, None)
        models_err = urllib.error.URLError("connection refused")

        def open_side_effect(*a, **kw):
            if "v1/models" in a[0]:
                raise models_err
            raise ps_err

        self.opener.open.side_effect = open_side_effect
        result = self._probe()
        self.assertFalse(result["reachable"])
        self.assertFalse(result["model_loaded"])

    def test_api_ps_url_error_leaves_reachable_false_and_skips_v1_models(self):
        import urllib.error
        url_err = urllib.error.URLError("connection refused")

        def open_side_effect(*a, **kw):
            raise url_err

        self.opener.open.side_effect = open_side_effect
        result = self._probe()
        self.assertFalse(result["reachable"])
        self.assertFalse(result["model_loaded"])
        urls = [c[0][0] for c in self.opener.open.call_args_list]
        self.assertEqual(len(urls), 1)
        self.assertIn("api/ps", urls[0])
        self.assertFalse(any("v1/models" in u for u in urls))


class SamplesLogTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")

    def tearDown(self):
        self._tmp.cleanup()

    def _samples(self):
        path = os.path.join(self.usage_dir, "samples.jsonl")
        with open(path, "r", encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    def test_first_run_appends_one_sample(self):
        proc = run(base_payload(), self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        samples = self._samples()
        self.assertEqual(len(samples), 1)
        self.assertEqual(samples[0]["family"], "claude")
        self.assertEqual(samples[0]["seven_day"]["used"], 10.0)

    def test_second_run_within_five_minutes_is_skipped(self):
        run(base_payload(), self.usage_dir)
        run(base_payload(), self.usage_dir)
        samples = self._samples()
        self.assertEqual(len(samples), 1)

    def test_a_run_after_five_minutes_appends_again(self):
        os.makedirs(self.usage_dir, exist_ok=True)
        old_ts = time.time() - 301
        with open(os.path.join(self.usage_dir, "samples.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({"ts": old_ts, "family": "claude",
                                 "five_hour": {"used": None}, "seven_day": {"used": 5}}) + "\n")
        run(base_payload(), self.usage_dir)
        samples = self._samples()
        self.assertEqual(len(samples), 2)

    def test_log_is_capped_at_2000_lines(self):
        os.makedirs(self.usage_dir, exist_ok=True)
        old_ts = time.time() - 301
        with open(os.path.join(self.usage_dir, "samples.jsonl"), "w", encoding="utf-8") as f:
            for i in range(2005):
                f.write(json.dumps({"ts": old_ts - (2005 - i), "family": "claude",
                                     "five_hour": {"used": None}, "seven_day": {"used": 5}}) + "\n")
        run(base_payload(), self.usage_dir)
        samples = self._samples()
        self.assertEqual(len(samples), 2000)


class CodexSegmentTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        os.makedirs(self.usage_dir, exist_ok=True)

    def tearDown(self):
        self._tmp.cleanup()

    def _write_codex_json(self, captured_at, five_used=None, seven_used=None,
                           five_resets=None, seven_resets=None):
        far_future = time.time() + 30 * 24 * 3600
        payload = {
            "source": "codex",
            "captured_at": captured_at,
            "five_hour": {"used_percentage": five_used,
                          "resets_at": five_resets if five_resets is not None else far_future}
            if five_used is not None else None,
            "seven_day": {"used_percentage": seven_used,
                          "resets_at": seven_resets if seven_resets is not None else far_future}
            if seven_used is not None else None,
        }
        with open(os.path.join(self.usage_dir, "codex.json"), "w", encoding="utf-8") as f:
            json.dump(payload, f)

    def test_fresh_codex_segment_shows_remaining_percent(self):
        self._write_codex_json(time.time(), five_used=38, seven_used=12)
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("codex: 62%/88%", proc.stdout)
        self.assertNotIn("stale", proc.stdout)

    def test_stale_codex_segment_renders_plain_text(self):
        self._write_codex_json(time.time() - 7200, five_used=10, seven_used=20)
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("codex: 90%/80%", proc.stdout)

    def test_stale_codex_snapshot_line_contains_no_stale(self):
        self._write_codex_json(time.time() - 7200, five_used=10, seven_used=20)
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        line = proc.stdout.strip()
        self.assertIn("codex: 90%/80%", line)
        self.assertNotIn("stale", line)

    def test_missing_codex_json_omits_segment(self):
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("codex:", proc.stdout)

    def test_partial_codex_snapshot_only_shows_available_window(self):
        self._write_codex_json(time.time(), five_used=None, seven_used=30)
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("codex: -/70%", proc.stdout)
        self.assertNotIn("codex: 70%/70%", proc.stdout)
        self.assertNotIn("codex: 70% ", proc.stdout)

    def test_partial_codex_snapshot_seven_day_only_with_near_reset_countdown(self):
        seven_resets = time.time() + 36 * 3600 + 1800
        self._write_codex_json(time.time(), five_used=None, seven_used=30,
                                seven_resets=seven_resets)
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("codex: -/70%(36h)", proc.stdout)

    def _write_codex_json_with_reached(self, five_used, seven_used, ordinary_usage_allowed):
        payload = {
            "source": "codex",
            "captured_at": time.time(),
            "five_hour": {"used_percentage": five_used, "resets_at": None},
            "seven_day": {"used_percentage": seven_used, "resets_at": None},
            "rate_limit_reached_type": "rate_limit_reached",
            "ordinary_usage_allowed": ordinary_usage_allowed,
        }
        with open(os.path.join(self.usage_dir, "codex.json"), "w", encoding="utf-8") as f:
            json.dump(payload, f)

    def test_limit_reached_forces_zero_remaining_on_binding_window(self):
        self._write_codex_json_with_reached(five_used=95, seven_used=10,
                                             ordinary_usage_allowed=False)
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("codex: 0%/90%", proc.stdout)

    def test_limit_reached_true_does_not_force_zero(self):
        self._write_codex_json_with_reached(five_used=95, seven_used=10,
                                             ordinary_usage_allowed=True)
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("codex: 5%/90%", proc.stdout)

    def test_passed_codex_reset_rolls_percent_even_if_snapshot_says_reached(self):
        payload = {
            "source": "codex", "captured_at": time.time(),
            "five_hour": {"used_percentage": 100, "resets_at": time.time() - 1},
            "seven_day": {"used_percentage": 20, "resets_at": time.time() + 4 * 24 * 3600},
            "ordinary_usage_allowed": False,
        }
        with open(os.path.join(self.usage_dir, "codex.json"), "w", encoding="ascii") as fh:
            json.dump(payload, fh)
        proc = run(base_payload(), self.usage_dir, extra_env={"CBOX_CODEX_USAGE_REFRESH": "off"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("codex: 100%/80%", proc.stdout)


class CodexRefreshTriggerTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        os.makedirs(self.usage_dir, exist_ok=True)
        self.saved_usage_dir = os.environ.pop("CBOX_USAGE_DIR", None)
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "usage_statusline_refresh_trigger", str(SCRIPT),
        )
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def tearDown(self):
        os.environ.pop("CBOX_USAGE_DIR", None)
        if self.saved_usage_dir is not None:
            os.environ["CBOX_USAGE_DIR"] = self.saved_usage_dir
        self._tmp.cleanup()

    def test_disabled_via_env_never_spawns(self):
        os.environ["CBOX_CODEX_USAGE_REFRESH"] = "off"
        try:
            with mock.patch.object(self.mod.subprocess, "Popen") as popen:
                self.mod._maybe_spawn_codex_refresh(time.time())
            popen.assert_not_called()
        finally:
            os.environ.pop("CBOX_CODEX_USAGE_REFRESH", None)

    def test_missing_snapshot_triggers_spawn_when_codex_present(self):
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.mod._maybe_spawn_codex_refresh(time.time())
        popen.assert_called_once()

    def test_no_codex_binary_skips_spawn(self):
        with mock.patch.object(self.mod.shutil, "which", return_value=None), \
                mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.mod._maybe_spawn_codex_refresh(time.time())
        popen.assert_not_called()

    def test_fresh_snapshot_does_not_trigger_spawn(self):
        with open(os.path.join(self.usage_dir, "codex.json"), "w", encoding="utf-8") as f:
            json.dump({"captured_at": time.time(), "five_hour": {"used_percentage": 1}}, f)
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.mod._maybe_spawn_codex_refresh(time.time())
        popen.assert_not_called()

    def test_cooldown_prevents_repeated_spawns(self):
        now = time.time()
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.mod._maybe_spawn_codex_refresh(now)
            self.mod._maybe_spawn_codex_refresh(now + 1)
        self.assertEqual(popen.call_count, 1)

    def test_snapshot_older_than_ten_minutes_triggers_spawn(self):
        now = time.time()
        with open(os.path.join(self.usage_dir, "codex.json"), "w", encoding="utf-8") as f:
            json.dump({"captured_at": now - 601, "five_hour": {"used_percentage": 1}}, f)
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.mod._maybe_spawn_codex_refresh(now)
        popen.assert_called_once()

    def test_snapshot_within_ten_minutes_does_not_trigger_spawn(self):
        now = time.time()
        with open(os.path.join(self.usage_dir, "codex.json"), "w", encoding="utf-8") as f:
            json.dump({"captured_at": now - 599, "five_hour": {"used_percentage": 1}}, f)
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.mod._maybe_spawn_codex_refresh(now)
        popen.assert_not_called()


class InProcessBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        os.makedirs(self.usage_dir, exist_ok=True)
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in NETWORK_ENV_VARS:
            os.environ.pop(name, None)
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir
        os.environ["CLAUDE_CONFIG_DIR"] = ABSENT_CFG
        os.environ["CBOX_CODEX_USAGE_REFRESH"] = "off"
        os.environ["CBOX_CLAUDE_USAGE_REFRESH"] = "off"
        os.environ["CBOX_HERMES_DELEGATE_LOCK_DIR"] = os.path.join(self._tmp.name, "locks-unused")
        os.environ["CBOX_HERMES_DELEGATE_RUNS_DIR"] = os.path.join(self._tmp.name, "runs-unused")
        import importlib.util
        spec = importlib.util.spec_from_file_location("usage_statusline_inproc", str(SCRIPT))
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def tearDown(self):
        self._tmp.cleanup()

    def path(self, name):
        return os.path.join(self.usage_dir, name)

    def snapshot(self):
        with open(self.path("claude.json"), "r", encoding="utf-8") as f:
            return json.load(f)

    def write_snapshot(self, captured_at, five=None, seven=None, source="claude-api"):
        with open(self.path("claude.json"), "w", encoding="utf-8") as f:
            json.dump({"source": source, "captured_at": captured_at,
                       "five_hour": five, "seven_day": seven}, f)

    def samples(self):
        try:
            with open(self.path("samples.jsonl"), "r", encoding="utf-8") as f:
                return [json.loads(line) for line in f if line.strip()]
        except FileNotFoundError:
            return []

    def state_files(self):
        return sorted(n for n in os.listdir(self.usage_dir) if n.startswith("statusline-session."))

    def step(self, now, rate_limits, session="sess-1"):
        data = {"session_id": session}
        if rate_limits is not _OMIT:
            data["rate_limits"] = rate_limits
        return self.mod._run(data, now)


_OMIT = object()
T0 = 1_800_000_000.0


def rl(five_used, five_resets, seven_used=None, seven_resets=None):
    out = {}
    if five_used is not None or five_resets is not None:
        out["five_hour"] = {"used_percentage": five_used, "resets_at": five_resets}
    if seven_used is not None or seven_resets is not None:
        out["seven_day"] = {"used_percentage": seven_used, "resets_at": seven_resets}
    return out


class SnapshotFreshnessTests(InProcessBase):
    def test_change_writes_snapshot_stamped_with_the_observation_time(self):
        line = self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        snap = self.snapshot()
        self.assertEqual(snap["source"], "claude")
        self.assertEqual(snap["captured_at"], T0)
        self.assertEqual(snap["five_hour"], {"used_percentage": 10.0, "resets_at": T0 + 3000, "captured_at": T0})
        self.assertEqual(snap["seven_day"], {"used_percentage": 20.0, "resets_at": T0 + 400000, "captured_at": T0})
        self.assertTrue(line.startswith("claude: 90%(50m)/80%"), line)

    def test_unchanged_rerun_does_not_rewrite_the_snapshot(self):
        payload = rl(10, T0 + 3000, 20, T0 + 400000)
        self.step(T0, payload)
        before = os.stat(self.path("claude.json")).st_mtime_ns
        self.step(T0 + 600, payload)
        self.assertEqual(self.snapshot()["captured_at"], T0)
        self.assertEqual(os.stat(self.path("claude.json")).st_mtime_ns, before)

    def test_stale_rerun_does_not_overwrite_a_newer_snapshot(self):
        payload = rl(10, T0 + 3000, 20, T0 + 400000)
        self.step(T0, payload)
        newer_five = {"used_percentage": 35.0, "resets_at": T0 + 3000}
        newer_seven = {"used_percentage": 25.0, "resets_at": T0 + 400000}
        self.write_snapshot(T0 + 100, newer_five, newer_seven)
        line = self.step(T0 + 200, payload)
        snap = self.snapshot()
        self.assertEqual(snap["captured_at"], T0 + 100)
        self.assertEqual(snap["source"], "claude-api")
        self.assertEqual(snap["five_hour"]["used_percentage"], 35.0)
        self.assertTrue(line.startswith("claude: 65%"), line)
        self.assertIn("/75%", line)

    def test_changed_stdin_writes_again_with_the_new_time(self):
        self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        self.step(T0 + 300, rl(15, T0 + 3000, 20, T0 + 400000))
        snap = self.snapshot()
        self.assertEqual(snap["captured_at"], T0 + 300)
        self.assertEqual(snap["five_hour"]["used_percentage"], 15.0)
        self.assertEqual(snap["seven_day"]["used_percentage"], 20.0)

    def test_null_window_never_overwrites_a_known_one(self):
        self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        self.step(T0 + 10, {"five_hour": None,
                            "seven_day": {"used_percentage": 21, "resets_at": T0 + 400000}})
        snap = self.snapshot()
        self.assertEqual(snap["captured_at"], T0 + 10)
        self.assertEqual(snap["five_hour"], {"used_percentage": 10.0, "resets_at": T0 + 3000, "captured_at": T0})
        self.assertEqual(snap["seven_day"]["used_percentage"], 21.0)
        self.assertEqual(snap["seven_day"]["captured_at"], T0 + 10)

    def test_window_without_a_percentage_never_overwrites_a_known_one(self):
        self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        self.step(T0 + 10, {"five_hour": {"used_percentage": None, "resets_at": T0 + 9000},
                            "seven_day": {"used_percentage": 22, "resets_at": T0 + 400000}})
        snap = self.snapshot()
        self.assertEqual(snap["five_hour"], {"used_percentage": 10.0, "resets_at": T0 + 3000, "captured_at": T0})

    def test_all_unknown_stdin_writes_nothing(self):
        self.step(T0, {"five_hour": None, "seven_day": {}})
        self.assertFalse(os.path.exists(self.path("claude.json")))
        self.assertEqual(self.state_files(), [])

    def test_unavailable_window_after_reset_shows_full_remaining(self):
        variants = {
            "null": {"five_hour": None, "seven_day": {"used_percentage": 20, "resets_at": T0 + 400000}},
            "missing": {"seven_day": {"used_percentage": 20, "resets_at": T0 + 400000}},
            "empty": {"five_hour": {}, "seven_day": {"used_percentage": 20, "resets_at": T0 + 400000}},
            "null_used": {"five_hour": {"used_percentage": None, "resets_at": None},
                          "seven_day": {"used_percentage": 20, "resets_at": T0 + 400000}},
        }
        for name, later in variants.items():
            with self.subTest(name):
                for f in os.listdir(self.usage_dir):
                    os.unlink(os.path.join(self.usage_dir, f))
                self.step(T0, rl(40, T0 + 100, 20, T0 + 400000))
                line = self.step(T0 + 200, later)
                self.assertTrue(line.startswith("claude: 100%/80%"), line)

    def test_expired_stdin_window_without_newer_data_shows_full_remaining(self):
        self.step(T0, rl(40, T0 + 100, 20, T0 + 400000))
        line = self.step(T0 + 500, rl(40, T0 + 100, 20, T0 + 400000))
        self.assertTrue(line.startswith("claude: 100%/80%"), line)

    def test_new_api_snapshot_beats_older_stdin_after_a_reset(self):
        self.step(T0, rl(40, T0 + 100, 20, T0 + 400000))
        self.write_snapshot(
            T0 + 150,
            {"used_percentage": 3.0, "resets_at": T0 + 100 + 18000},
            {"used_percentage": 21.0, "resets_at": T0 + 400000},
        )
        line = self.step(T0 + 200, rl(40, T0 + 100, 20, T0 + 400000))
        self.assertTrue(line.startswith("claude: 97%/79%"), line)

    def test_newer_stdin_beats_older_api_snapshot(self):
        self.write_snapshot(
            T0,
            {"used_percentage": 50.0, "resets_at": T0 + 3000},
            {"used_percentage": 30.0, "resets_at": T0 + 400000},
        )
        line = self.step(T0 + 120, rl(60, T0 + 3000, 31, T0 + 400000))
        self.assertTrue(line.startswith("claude: 40%"), line)
        self.assertIn("/69%", line)

    def test_future_dated_snapshot_does_not_pin_the_display(self):
        self.write_snapshot(
            T0 + 10 ** 7,
            {"used_percentage": 90.0, "resets_at": T0 + 3000},
            {"used_percentage": 90.0, "resets_at": T0 + 400000},
        )
        line = self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        self.assertTrue(line.startswith("claude: 90%"), line)

    def test_first_run_with_an_older_window_does_not_clobber_the_snapshot(self):
        self.write_snapshot(
            T0 - 30,
            {"used_percentage": 5.0, "resets_at": T0 + 17000},
            {"used_percentage": 20.0, "resets_at": T0 + 400000},
        )
        self.step(T0, rl(95, T0 + 1000, 20, T0 + 400000), session="fresh-session")
        snap = self.snapshot()
        self.assertEqual(snap["five_hour"]["used_percentage"], 5.0)
        self.assertEqual(snap["five_hour"]["resets_at"], T0 + 17000)

    def test_samples_are_appended_only_on_change(self):
        payload = rl(10, T0 + 3000, 20, T0 + 400000)
        self.step(T0, payload)
        self.step(T0 + 1000, payload)
        self.step(T0 + 2000, payload)
        self.assertEqual(len(self.samples()), 1)
        self.step(T0 + 3000, rl(11, T0 + 3500, 20, T0 + 400000))
        samples = self.samples()
        self.assertEqual(len(samples), 2)
        self.assertEqual(samples[-1]["five_hour"]["used"], 11.0)

    def test_budget_reader_accepts_the_written_snapshot(self):
        self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        budget = self.mod._cbox_budget_mod()
        m = budget.source_metrics("claude", T0 + 60)
        self.assertIsNotNone(m)
        self.assertEqual(m["captured_at"], T0)
        self.assertEqual(m["five_hour"]["used_percentage"], 10.0)
        self.assertEqual(m["seven_day"]["used_percentage"], 20.0)

    def test_rerun_without_rate_limits_shows_the_snapshot(self):
        self.write_snapshot(
            T0,
            {"used_percentage": 25.0, "resets_at": T0 + 3000},
            {"used_percentage": 20.0, "resets_at": T0 + 400000},
        )
        line = self.step(T0 + 60, _OMIT)
        self.assertTrue(line.startswith("claude: 75%"), line)
        self.assertIn("/80%", line)


class SessionStateTests(InProcessBase):
    def test_state_file_is_private_hashed_and_free_of_the_raw_id(self):
        self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000), session="secret-session-id")
        files = self.state_files()
        self.assertEqual(len(files), 1)
        self.assertNotIn("secret-session-id", files[0])
        mode = stat.S_IMODE(os.stat(self.path(files[0])).st_mode)
        self.assertEqual(mode, 0o600)
        with open(self.path(files[0]), "r", encoding="utf-8") as f:
            self.assertNotIn("secret-session-id", f.read())

    def test_sessions_are_tracked_independently(self):
        now = time.time()
        payload = rl(10, now + 3000, 20, now + 400000)
        self.step(now, payload, session="a")
        self.step(now + 10, payload, session="b")
        self.assertEqual(len(self.state_files()), 2)
        self.assertEqual(self.snapshot()["captured_at"], now + 10)
        self.step(now + 20, payload, session="a")
        self.assertEqual(self.snapshot()["captured_at"], now + 10)

    def test_state_files_are_capped(self):
        now = time.time()
        for i in range(45):
            self.step(now + i, rl(10 + i % 5, now + 3000, 20, now + 400000), session="s%d" % i)
        self.assertLessEqual(len(self.state_files()), 32)

    def test_aged_state_files_are_pruned_on_the_next_change(self):
        now = time.time()
        self.step(now, rl(10, now + 3000, 20, now + 400000), session="old")
        old = self.path(self.state_files()[0])
        aged = now - 8 * 24 * 3600
        os.utime(old, (aged, aged))
        self.step(now + 5, rl(10, now + 3000, 20, now + 400000), session="new")
        self.assertFalse(os.path.exists(old))
        self.assertEqual(len(self.state_files()), 1)

    def test_symlinked_state_file_is_not_followed(self):
        outside = os.path.join(self._tmp.name, "outside.json")
        with open(outside, "w", encoding="utf-8") as f:
            f.write(json.dumps({"five_hour": {"used_percentage": 99, "resets_at": T0 + 3000, "at": T0}}))
        key = self.mod._session_key({"session_id": "sess-1"})
        os.symlink(outside, self.mod._session_state_path(key))
        self.assertIsNone(self.mod._read_session_state(key, T0))

    def test_garbage_state_file_is_treated_as_first_run(self):
        key = self.mod._session_key({"session_id": "sess-1"})
        with open(self.mod._session_state_path(key), "w", encoding="utf-8") as f:
            f.write("{{{ not json")
        line = self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        self.assertTrue(line.startswith("claude: 90%"), line)
        self.assertEqual(self.snapshot()["captured_at"], T0)


class ClaudeRefreshTriggerTests(InProcessBase):
    def setUp(self):
        super().setUp()
        os.environ.pop("CBOX_CLAUDE_USAGE_REFRESH", None)

    def _spawn(self, now):
        with mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.mod._maybe_spawn_claude_refresh(now)
        return popen

    def test_disabled_via_env_never_spawns(self):
        os.environ["CBOX_CLAUDE_USAGE_REFRESH"] = "off"
        self._spawn(T0).assert_not_called()
        self.assertFalse(os.path.exists(self.path("claude_refresh_attempt.json")))

    def test_missing_snapshot_triggers_spawn(self):
        popen = self._spawn(T0)
        popen.assert_called_once()
        argv = popen.call_args[0][0]
        self.assertTrue(argv[1].endswith("claude_usage_refresh.py"))
        kwargs = popen.call_args[1]
        self.assertTrue(kwargs.get("start_new_session"))

    def test_fresh_snapshot_does_not_trigger_spawn(self):
        self.write_snapshot(T0 - 299, {"used_percentage": 1.0, "resets_at": T0 + 100})
        self._spawn(T0).assert_not_called()

    def test_snapshot_older_than_the_interval_triggers_spawn(self):
        self.write_snapshot(T0 - 301, {"used_percentage": 1.0, "resets_at": T0 + 100})
        self._spawn(T0).assert_called_once()

    def test_attempt_stamp_prevents_retry_storms(self):
        self.write_snapshot(T0 - 1000, {"used_percentage": 1.0, "resets_at": T0 + 100})
        self.assertEqual(self._spawn(T0).call_count, 1)
        self._spawn(T0 + 60).assert_not_called()
        self._spawn(T0 + 299).assert_not_called()
        self._spawn(T0 + 301).assert_called_once()

    def test_backoff_window_blocks_spawn(self):
        self.write_snapshot(T0 - 1000, {"used_percentage": 1.0, "resets_at": T0 + 100})
        with open(self.path("claude_refresh_attempt.json"), "w", encoding="utf-8") as f:
            json.dump({"ts": T0 - 900, "backoff_until": T0 + 600}, f)
        self._spawn(T0).assert_not_called()
        self._spawn(T0 + 601).assert_called_once()

    def test_spawn_keeps_the_pollers_stop_marker(self):
        with open(self.path("claude_refresh_attempt.json"), "w", encoding="utf-8") as f:
            json.dump({"ts": T0 - 900, "stop_expires_at": 12345}, f)
        self._spawn(T0).assert_called_once()
        with open(self.path("claude_refresh_attempt.json"), "r", encoding="utf-8") as f:
            stamp = json.load(f)
        self.assertEqual(stamp["stop_expires_at"], 12345)
        self.assertEqual(stamp["ts"], T0)

    def test_interval_env_is_honored_with_a_sixty_second_floor(self):
        self.write_snapshot(T0 - 100, {"used_percentage": 1.0, "resets_at": T0 + 100})
        os.environ["CBOX_CLAUDE_USAGE_REFRESH_SEC"] = "600"
        self._spawn(T0).assert_not_called()
        os.environ["CBOX_CLAUDE_USAGE_REFRESH_SEC"] = "5"
        self.assertEqual(self.mod._claude_refresh_interval(), 60)
        self._spawn(T0).assert_called_once()

    def test_invalid_interval_env_falls_back_to_default(self):
        for raw in ("", "abc", "nan", "inf"):
            os.environ["CBOX_CLAUDE_USAGE_REFRESH_SEC"] = raw
            self.assertEqual(self.mod._claude_refresh_interval(), 300)

    def test_spawn_failure_is_swallowed(self):
        with mock.patch.object(self.mod.subprocess, "Popen", side_effect=OSError("x")):
            self.mod._maybe_spawn_claude_refresh(T0)

    def test_statusline_run_spawns_through_the_run_path(self):
        with mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        popen.assert_not_called()
        with mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.step(T0 + 400, rl(10, T0 + 3000, 20, T0 + 400000))
        popen.assert_called_once()


class SnapshotIntegrityTests(InProcessBase):
    def test_carried_over_window_keeps_its_own_stamp(self):
        self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        self.step(T0 + 500, rl(12, T0 + 3000, 20, T0 + 400000))
        snap = self.snapshot()
        self.assertEqual(snap["captured_at"], T0 + 500)
        self.assertEqual(snap["five_hour"]["captured_at"], T0 + 500)
        self.assertEqual(snap["seven_day"]["captured_at"], T0)

    def test_lower_usage_in_the_same_window_never_replaces_the_snapshot(self):
        self.write_snapshot(
            T0 - 10,
            {"used_percentage": 40.0, "resets_at": T0 + 3000},
            {"used_percentage": 20.0, "resets_at": T0 + 400000},
        )
        line = self.step(T0, {"five_hour": {"used_percentage": 30, "resets_at": T0 + 3010}})
        self.assertEqual(self.snapshot()["five_hour"]["used_percentage"], 40.0)
        self.assertTrue(line.startswith("claude: 60%"), line)
        self.assertEqual(self.samples(), [])

    def test_lower_usage_without_a_real_difference_writes_nothing(self):
        self.write_snapshot(
            T0 - 10,
            {"used_percentage": 40.0, "resets_at": T0 + 3000},
            None,
        )
        before = os.stat(self.path("claude.json")).st_mtime_ns
        self.step(T0, {"five_hour": {"used_percentage": 30, "resets_at": T0 + 3010}})
        self.assertEqual(os.stat(self.path("claude.json")).st_mtime_ns, before)

    def test_a_real_roll_replaces_with_lower_usage(self):
        self.write_snapshot(
            T0 - 10,
            {"used_percentage": 90.0, "resets_at": T0 + 100},
            None,
        )
        self.step(T0 + 200, {"five_hour": {"used_percentage": 2, "resets_at": T0 + 100 + 18000}})
        snap = self.snapshot()
        self.assertEqual(snap["five_hour"]["used_percentage"], 2.0)
        self.assertEqual(snap["five_hour"]["captured_at"], T0 + 200)

    def test_unknown_resets_never_replaces_a_known_resets(self):
        self.write_snapshot(
            T0 - 10,
            {"used_percentage": 10.0, "resets_at": T0 + 3000},
            None,
        )
        self.step(T0, {"five_hour": {"used_percentage": 50, "resets_at": None}})
        snap = self.snapshot()
        self.assertEqual(snap["five_hour"]["used_percentage"], 10.0)
        self.assertEqual(snap["five_hour"]["resets_at"], T0 + 3000)

    def test_display_keeps_usage_monotonic_within_a_window(self):
        self.write_snapshot(
            T0,
            {"used_percentage": 40.0, "resets_at": T0 + 3000},
            {"used_percentage": 20.0, "resets_at": T0 + 400000},
        )
        line = self.step(T0 + 100, rl(30, T0 + 3000, 20, T0 + 400000), session="other")
        self.assertTrue(line.startswith("claude: 60%"), line)

    def test_implausible_stdin_resets_is_ignored(self):
        self.step(T0, {"five_hour": {"used_percentage": 50, "resets_at": T0 + 10 ** 7},
                       "seven_day": {"used_percentage": 20, "resets_at": T0 + 10 ** 8}})
        self.assertFalse(os.path.exists(self.path("claude.json")))
        self.assertEqual(self.state_files(), [])

    def test_implausible_snapshot_window_is_ignored_in_display(self):
        self.write_snapshot(
            T0,
            {"used_percentage": 99.0, "resets_at": T0 + 10 ** 7},
            {"used_percentage": 20.0, "resets_at": T0 + 400000},
        )
        line = self.step(T0 + 10, _OMIT)
        self.assertTrue(line.startswith("claude: -/80%") or line.startswith("claude: 80%"), line)
        self.assertNotIn("1%", line.split("|")[0])

    def test_future_stamped_snapshot_is_excluded_from_display(self):
        self.write_snapshot(
            T0 + 10 ** 6,
            {"used_percentage": 90.0, "resets_at": T0 + 3000},
            {"used_percentage": 90.0, "resets_at": T0 + 400000},
        )
        line = self.step(T0, _OMIT)
        self.assertNotIn("claude:", line)

    def test_future_window_stamp_is_excluded_per_window(self):
        with open(self.path("claude.json"), "w", encoding="utf-8") as f:
            json.dump({
                "source": "claude-api", "captured_at": T0,
                "five_hour": {"used_percentage": 90.0, "resets_at": T0 + 3000, "captured_at": T0 + 10 ** 6},
                "seven_day": {"used_percentage": 20.0, "resets_at": T0 + 400000, "captured_at": T0},
            }, f)
        line = self.step(T0, _OMIT)
        self.assertTrue(line.startswith("claude: -/80%"), line)

    def test_held_snapshot_lock_skips_the_write_but_not_the_display(self):
        fd = os.open(self.path("claude.json.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            started = time.monotonic()
            line = self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
            elapsed = time.monotonic() - started
        finally:
            os.close(fd)
        self.assertLess(elapsed, 2.0)
        self.assertFalse(os.path.exists(self.path("claude.json")))
        self.assertTrue(line.startswith("claude: 90%"), line)

    def test_deeply_nested_snapshot_and_state_files_are_unreadable_not_fatal(self):
        with open(self.path("claude.json"), "w", encoding="utf-8") as f:
            f.write("[" * 60000)
        key = self.mod._session_key({"session_id": "sess-1"})
        with open(self.mod._session_state_path(key), "w", encoding="utf-8") as f:
            f.write("[" * 60000)
        line = self.step(T0, rl(10, T0 + 3000, 20, T0 + 400000))
        self.assertTrue(line.startswith("claude: 90%"), line)
        self.assertEqual(self.snapshot()["five_hour"]["used_percentage"], 10.0)


class ClaudeRefreshHardeningTests(InProcessBase):
    def setUp(self):
        super().setUp()
        os.environ.pop("CBOX_CLAUDE_USAGE_REFRESH", None)

    def _spawn(self, now):
        with mock.patch.object(self.mod.subprocess, "Popen") as popen:
            self.mod._maybe_spawn_claude_refresh(now)
        return popen

    def test_one_stale_window_triggers_a_refresh_even_when_the_other_is_fresh(self):
        with open(self.path("claude.json"), "w", encoding="utf-8") as f:
            json.dump({
                "source": "claude", "captured_at": T0,
                "five_hour": {"used_percentage": 1.0, "resets_at": T0 + 3000, "captured_at": T0},
                "seven_day": {"used_percentage": 1.0, "resets_at": T0 + 400000, "captured_at": T0 - 301},
            }, f)
        self._spawn(T0).assert_called_once()

    def test_all_windows_fresh_does_not_trigger(self):
        with open(self.path("claude.json"), "w", encoding="utf-8") as f:
            json.dump({
                "source": "claude", "captured_at": T0,
                "five_hour": {"used_percentage": 1.0, "resets_at": T0 + 3000, "captured_at": T0 - 10},
                "seven_day": {"used_percentage": 1.0, "resets_at": T0 + 400000, "captured_at": T0},
            }, f)
        self._spawn(T0).assert_not_called()

    def test_future_stamped_snapshot_counts_as_needing_refresh(self):
        self.write_snapshot(T0 + 10 ** 6, {"used_percentage": 1.0, "resets_at": T0 + 3000})
        self._spawn(T0).assert_called_once()

    def test_absurd_backoff_stamp_is_ignored(self):
        self.write_snapshot(T0 - 1000, {"used_percentage": 1.0, "resets_at": T0 + 3000})
        with open(self.path("claude_refresh_attempt.json"), "w", encoding="utf-8") as f:
            json.dump({"ts": T0 - 900, "backoff_until": T0 + 10 ** 9}, f)
        self._spawn(T0).assert_called_once()

    def test_reasonable_backoff_stamp_still_blocks(self):
        self.write_snapshot(T0 - 1000, {"used_percentage": 1.0, "resets_at": T0 + 3000})
        with open(self.path("claude_refresh_attempt.json"), "w", encoding="utf-8") as f:
            json.dump({"ts": T0 - 900, "backoff_until": T0 + 6 * 3600}, f)
        self._spawn(T0).assert_not_called()

    def test_deeply_nested_attempt_stamp_is_unreadable_not_fatal(self):
        self.write_snapshot(T0 - 1000, {"used_percentage": 1.0, "resets_at": T0 + 3000})
        with open(self.path("claude_refresh_attempt.json"), "w", encoding="utf-8") as f:
            f.write("[" * 60000)
        self._spawn(T0).assert_called_once()


class IdleRerunProcessTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")

    def tearDown(self):
        self._tmp.cleanup()

    def test_second_process_run_keeps_the_first_snapshot_time(self):
        payload = json.dumps({
            "session_id": "proc-1",
            "rate_limits": {
                "five_hour": {"used_percentage": 12, "resets_at": time.time() + 3000},
                "seven_day": {"used_percentage": 30, "resets_at": time.time() + 400000},
            },
        })
        run(payload, self.usage_dir)
        path = os.path.join(self.usage_dir, "claude.json")
        with open(path, "r", encoding="utf-8") as f:
            first = json.load(f)
        time.sleep(0.05)
        proc = run(payload, self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(path, "r", encoding="utf-8") as f:
            second = json.load(f)
        self.assertEqual(first["captured_at"], second["captured_at"])
        self.assertIn("claude: 88%", proc.stdout)


class HermesSegmentTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        self.lock_dir = os.path.join(self._tmp.name, "hermes-locks")
        self.runs_dir = os.path.join(self._tmp.name, "hermes-runs")
        self._held_fd = None

    def tearDown(self):
        if self._held_fd is not None:
            try:
                fcntl.flock(self._held_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(self._held_fd)
        self._tmp.cleanup()

    def _hold_slot(self):
        os.makedirs(self.lock_dir, exist_ok=True)
        path = os.path.join(self.lock_dir, "slot.0")
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o666)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self._held_fd = fd

    def _write_unfinished(self, rid):
        os.makedirs(os.path.join(self.runs_dir, rid), exist_ok=True)

    def _write_finished(self, rid, started_epoch, ended_epoch):
        d = os.path.join(self.runs_dir, rid)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "summary.json"), "w", encoding="utf-8") as f:
            json.dump({"run_id": rid, "outcome": "ok", "started": iso(started_epoch),
                        "ended": iso(ended_epoch)}, f)

    def _run(self):
        return run(json.dumps({}), self.usage_dir, extra_env={
            "CBOX_HERMES_DELEGATE_LOCK_DIR": self.lock_dir,
            "CBOX_HERMES_DELEGATE_RUNS_DIR": self.runs_dir,
        })

    def test_idle_when_no_slot_is_held(self):
        proc = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: idle")

    def test_estimate_uses_median_of_history(self):
        self._hold_slot()
        now = time.time()
        self._write_unfinished(run_id(now - 120, 1))
        for i, offset in enumerate((300, 300, 300), start=2):
            started = now - 3600 - i * 10
            self._write_finished(run_id(started, i), started, started + offset)
        proc = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: ~3min")

    def test_no_history_shows_elapsed_without_tilde(self):
        self._hold_slot()
        now = time.time()
        self._write_unfinished(run_id(now - 60, 1))
        proc = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: 1min")

    def test_overdue_shows_tilde_zero(self):
        self._hold_slot()
        now = time.time()
        self._write_unfinished(run_id(now - 400, 1))
        started = now - 3600
        self._write_finished(run_id(started, 2), started, started + 300)
        proc = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: ~0min")


class HermesPresenceSegmentTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        os.makedirs(self.usage_dir, exist_ok=True)
        self.lock_dir = os.path.join(self._tmp.name, "locks")
        self.runs_dir = os.path.join(self._tmp.name, "runs")
        self._held_fd = None

    def tearDown(self):
        if self._held_fd is not None:
            fcntl.flock(self._held_fd, fcntl.LOCK_UN)
            os.close(self._held_fd)
        self._tmp.cleanup()

    def _snapshot(self, reachable, age=0, history=None):
        ts = time.time() - age
        doc = {"ts": ts, "last_probe_ts": ts, "reachable": reachable,
               "model_loaded": False,
               "history": history if history is not None else [reachable, reachable]}
        with open(os.path.join(self.usage_dir, "hermes.json"), "w", encoding="utf-8") as f:
            json.dump(doc, f)

    def _hold_slot(self):
        os.makedirs(self.lock_dir, exist_ok=True)
        fd = os.open(os.path.join(self.lock_dir, "slot.0"), os.O_CREAT | os.O_RDWR, 0o666)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self._held_fd = fd

    def _run(self, cfg=PRESENT_CFG, payload=None):
        return run(json.dumps(payload or {}), self.usage_dir, extra_env={
            "CLAUDE_CONFIG_DIR": cfg,
            "CBOX_HERMES_DELEGATE_LOCK_DIR": self.lock_dir,
            "CBOX_HERMES_DELEGATE_RUNS_DIR": self.runs_dir,
        })

    def test_absent_tier_omits_the_segment_entirely(self):
        proc = self._run(cfg=ABSENT_CFG)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("hermes", proc.stdout)

    def test_absent_tier_omits_the_segment_even_when_a_slot_is_busy(self):
        self._hold_slot()
        proc = self._run(cfg=ABSENT_CFG)
        self.assertNotIn("hermes", proc.stdout)

    def test_missing_config_file_omits_the_segment(self):
        proc = self._run(cfg=os.path.join(self._tmp.name, "no-such-dir"))
        self.assertNotIn("hermes", proc.stdout)

    def test_an_unreadable_config_keeps_the_segment(self):
        bad = os.path.join(_CFG_ROOT, "invalid")
        os.makedirs(bad, exist_ok=True)
        with open(os.path.join(bad, ".claude.json"), "w", encoding="utf-8") as f:
            f.write("{oops")
        proc = self._run(cfg=bad)
        self.assertEqual(proc.stdout.strip(), "hermes: idle")

    def test_unreachable_snapshot_shows_down(self):
        self._snapshot(False)
        proc = self._run()
        self.assertEqual(proc.stdout.strip(), "hermes: down")

    def test_reachable_snapshot_shows_idle(self):
        self._snapshot(True)
        proc = self._run()
        self.assertEqual(proc.stdout.strip(), "hermes: idle")

    def test_no_snapshot_shows_idle(self):
        proc = self._run()
        self.assertEqual(proc.stdout.strip(), "hermes: idle")

    def test_stale_unreachable_snapshot_shows_idle(self):
        self._snapshot(False, age=3600)
        proc = self._run()
        self.assertEqual(proc.stdout.strip(), "hermes: idle")

    def test_a_single_failed_probe_after_a_good_one_shows_idle(self):
        self._snapshot(False, history=[True, False])
        proc = self._run()
        self.assertEqual(proc.stdout.strip(), "hermes: idle")

    def test_busy_slot_wins_over_unreachable_snapshot(self):
        self._snapshot(False)
        self._hold_slot()
        proc = self._run()
        self.assertEqual(proc.stdout.strip(), "hermes: 0min")

    def test_project_scoped_server_matches_the_status_cwd_exactly(self):
        cfg = _make_cfg("scoped", {"projects": {"/work/proj": {"mcpServers": {"hermes-local": {}}}}})
        proc = self._run(cfg=cfg, payload={"cwd": "/work/proj"})
        self.assertEqual(proc.stdout.strip(), "hermes: idle")
        proc = self._run(cfg=cfg, payload={"cwd": "/work/proj/sub"})
        self.assertNotIn("hermes", proc.stdout)
        proc = self._run(cfg=cfg, payload={"cwd": "/work/other"})
        self.assertNotIn("hermes", proc.stdout)

    def test_down_is_dropped_before_the_seven_day_numbers_on_a_narrow_line(self):
        self._snapshot(False)
        payload = {"rate_limits": {"five_hour": {"used_percentage": 50, "resets_at": time.time() + 3600},
                                   "seven_day": {"used_percentage": 25, "resets_at": time.time() + 86400}},
                   "columns": 24}
        proc = self._run(payload=payload)
        self.assertNotIn("hermes", proc.stdout)


class AgentsSegmentTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        os.makedirs(self.usage_dir, exist_ok=True)

    def tearDown(self):
        self._tmp.cleanup()

    def _write_override(self, until, b):
        with open(os.path.join(self.usage_dir, "override.json"), "w", encoding="utf-8") as f:
            json.dump({"until": until, "b": b}, f)

    def test_override_b_zero_shows_agents_zero(self):
        self._write_override(time.time() + 60, 0.0)
        proc = run(json.dumps({}), self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("agents: 0", proc.stdout)

    def test_override_b_two_point_nine_shows_agents_three(self):
        self._write_override(time.time() + 60, 2.9)
        proc = run(json.dumps({}), self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("agents: 3", proc.stdout)

    def test_no_data_omits_agents_segment_when_unknown(self):
        proc = run(json.dumps({}), self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("agents:", proc.stdout)


class ProfileSegmentTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")

    def tearDown(self):
        self._tmp.cleanup()

    def test_profile_set_is_shown_as_prefix(self):
        proc = run(json.dumps({}), self.usage_dir, extra_env={"CBOX_PROFILE": "dev"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "[dev] hermes: idle")

    def test_profile_unset_has_no_prefix(self):
        proc = run(json.dumps({}), self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "hermes: idle")
        self.assertNotIn("[", proc.stdout)


class ExactLineFixtureTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        os.makedirs(self.usage_dir, exist_ok=True)
        self.lock_dir = os.path.join(self._tmp.name, "hermes-locks")
        self.runs_dir = os.path.join(self._tmp.name, "hermes-runs")
        self._held_fd = None

    def tearDown(self):
        if self._held_fd is not None:
            try:
                fcntl.flock(self._held_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(self._held_fd)
        self._tmp.cleanup()

    def _hold_slot(self):
        os.makedirs(self.lock_dir, exist_ok=True)
        path = os.path.join(self.lock_dir, "slot.0")
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o666)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self._held_fd = fd

    def _write_codex_json(self, five_used, seven_used, five_offset=None, seven_offset=None):
        now = time.time()
        five_offset = five_offset if five_offset is not None else 30 * 24 * 3600
        seven_offset = seven_offset if seven_offset is not None else 30 * 24 * 3600
        payload = {
            "source": "codex",
            "captured_at": now,
            "five_hour": {"used_percentage": five_used, "resets_at": now + five_offset},
            "seven_day": {"used_percentage": seven_used, "resets_at": now + seven_offset},
        }
        with open(os.path.join(self.usage_dir, "codex.json"), "w", encoding="utf-8") as f:
            json.dump(payload, f)

    def _write_override(self, b):
        with open(os.path.join(self.usage_dir, "override.json"), "w", encoding="utf-8") as f:
            json.dump({"until": time.time() + 60, "b": b}, f)

    def _seed_full_data(self, countdown=False):
        if countdown:
            self._write_codex_json(30, 20, five_offset=40 * 60 + 30, seven_offset=10 * 24 * 3600)
        else:
            self._write_codex_json(30, 20)
        self._write_override(1.8)
        self._hold_slot()
        now = time.time()
        os.makedirs(os.path.join(self.runs_dir, run_id(now, 1)), exist_ok=True)
        started = now - 3600
        d = os.path.join(self.runs_dir, run_id(started, 2))
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "summary.json"), "w", encoding="utf-8") as f:
            json.dump({"run_id": "hist", "outcome": "ok", "started": iso(started),
                        "ended": iso(started + 1200)}, f)

    def _payload(self, five_used=60, seven_used=56, five_offset=None, seven_offset=None):
        now = time.time()
        five_offset = five_offset if five_offset is not None else 30 * 24 * 3600
        seven_offset = seven_offset if seven_offset is not None else 30 * 24 * 3600
        return json.dumps({
            "rate_limits": {
                "five_hour": {"used_percentage": five_used, "resets_at": now + five_offset},
                "seven_day": {"used_percentage": seven_used, "resets_at": now + seven_offset},
            },
        })

    def _run(self, extra_env=None, payload_kwargs=None):
        env = {
            "CBOX_HERMES_DELEGATE_LOCK_DIR": self.lock_dir,
            "CBOX_HERMES_DELEGATE_RUNS_DIR": self.runs_dir,
        }
        if extra_env:
            env.update(extra_env)
        kwargs = payload_kwargs or {}
        return run(self._payload(**kwargs), self.usage_dir, extra_env=env)

    def test_wide_line_shows_all_segments(self):
        self._seed_full_data()
        proc = self._run(extra_env={"CBOX_PROFILE": "myprofile"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            "[myprofile] claude: 40%/44% | codex: 70%/80% | hermes: ~20min | agents: 2",
        )

    def test_wide_line_shows_near_reset_countdowns(self):
        self._seed_full_data(countdown=True)
        proc = self._run(
            extra_env={"CBOX_PROFILE": "myprofile"},
            payload_kwargs={
                "five_used": 50, "seven_used": 25,
                "five_offset": 15 * 60 + 30, "seven_offset": 36 * 3600 + 1800,
            },
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            "[myprofile] claude: 50%(15m)/75%(36h) | codex: 70%(40m)/80% | hermes: ~20min | agents: 2",
        )

    def test_narrow_width_drop_order_countdown_agents_hermes_seven_day(self):
        self._seed_full_data(countdown=True)
        payload_kwargs = {
            "five_used": 50, "seven_used": 25,
            "five_offset": 15 * 60 + 30, "seven_offset": 36 * 3600 + 1800,
        }
        proc80 = self._run(extra_env={"CBOX_PROFILE": "myprofile", "COLUMNS": "80"},
                            payload_kwargs=payload_kwargs)
        self.assertEqual(proc80.returncode, 0, proc80.stderr)
        self.assertEqual(
            proc80.stdout.strip(),
            "[myprofile] claude: 50%/75% | codex: 70%/80% | hermes: ~20min | agents: 2",
        )

        proc65 = self._run(extra_env={"CBOX_PROFILE": "myprofile", "COLUMNS": "65"},
                            payload_kwargs=payload_kwargs)
        self.assertEqual(proc65.returncode, 0, proc65.stderr)
        self.assertEqual(
            proc65.stdout.strip(),
            "[myprofile] claude: 50%/75% | codex: 70%/80% | hermes: ~20min",
        )

        proc50 = self._run(extra_env={"CBOX_PROFILE": "myprofile", "COLUMNS": "50"},
                            payload_kwargs=payload_kwargs)
        self.assertEqual(proc50.returncode, 0, proc50.stderr)
        self.assertEqual(
            proc50.stdout.strip(),
            "[myprofile] claude: 50%/75% | codex: 70%/80%",
        )

        proc40 = self._run(extra_env={"CBOX_PROFILE": "myprofile", "COLUMNS": "40"},
                            payload_kwargs=payload_kwargs)
        self.assertEqual(proc40.returncode, 0, proc40.stderr)
        self.assertEqual(
            proc40.stdout.strip(),
            "[myprofile] claude: 50% | codex: 70%",
        )

    def test_narrow_line_drops_agents_then_hermes_then_seven_day(self):
        self._seed_full_data()
        proc = self._run(extra_env={"CBOX_PROFILE": "myprofile", "COLUMNS": "10"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            "[myprofile] claude: 40% | codex: 70%",
        )

    def test_missing_segment_is_omitted_entirely(self):
        self._write_override(1.8)
        proc = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            "claude: 40%/44% | hermes: idle | agents: 2",
        )
        self.assertNotIn("codex:", proc.stdout)

    def test_no_color_never_emits_ansi_codes(self):
        self._write_override(1.8)
        proc = self._run(extra_env={"NO_COLOR": "1"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("\x1b", proc.stdout)
        proc2 = self._run(extra_env={"NO_COLOR": ""})
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        self.assertNotIn("\x1b", proc2.stdout)
        self.assertEqual(proc.stdout, proc2.stdout)


class ResetCountdownUnitTests(unittest.TestCase):
    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "usage_statusline_countdown", str(SCRIPT),
        )
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def test_five_hour_59_minutes_is_shown(self):
        self.assertEqual(
            self.mod._reset_countdown(59 * 60, 0, "five_hour"), "(59m)",
        )

    def test_five_hour_61_minutes_is_not_shown(self):
        self.assertEqual(
            self.mod._reset_countdown(61 * 60, 0, "five_hour"), "",
        )

    def test_seven_day_47_hours_is_shown(self):
        self.assertEqual(
            self.mod._reset_countdown(47 * 3600, 0, "seven_day"), "(47h)",
        )

    def test_seven_day_49_hours_is_not_shown(self):
        self.assertEqual(
            self.mod._reset_countdown(49 * 3600, 0, "seven_day"), "",
        )

    def test_missing_resets_at_yields_no_countdown(self):
        self.assertEqual(self.mod._reset_countdown(None, 0, "five_hour"), "")
        self.assertEqual(self.mod._reset_countdown(None, 0, "seven_day"), "")

    def test_past_resets_at_rolls_to_next_window(self):
        self.assertEqual(self.mod._reset_countdown(-100, 0, "five_hour"), "")
        self.assertEqual(self.mod._reset_countdown(-100, 0, "seven_day"), "")


class DualSegmentSevenDayOnlyTests(unittest.TestCase):
    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "usage_statusline_dual", str(SCRIPT),
        )
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def test_seven_day_only_renders_dashed_five_slot(self):
        text = self.mod._dual_segment("codex", None, "40%", False)
        self.assertEqual(text, "codex: -/40%")

    def test_seven_day_only_is_dropped_when_seven_is_dropped(self):
        self.assertIsNone(self.mod._dual_segment("codex", None, "40%", True))

    def test_other_cases_unchanged(self):
        self.assertEqual(
            self.mod._dual_segment("claude", "60%", "80%", False),
            "claude: 60%/80%",
        )
        self.assertEqual(
            self.mod._dual_segment("claude", "60%", "80%", True),
            "claude: 60%",
        )
        self.assertEqual(
            self.mod._dual_segment("codex", "55%", None, False),
            "codex: 55%",
        )
        self.assertIsNone(self.mod._dual_segment("codex", None, None, False))
        self.assertEqual(
            self.mod._dual_segment("codex", None, "40%", False),
            "codex: -/40%",
        )


class SafeReadTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = self._tmp.name
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "usage_statusline_saferead", str(SCRIPT),
        )
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def tearDown(self):
        self._tmp.cleanup()

    def test_symlinked_json_is_not_followed(self):
        target = os.path.join(self.base, "outside.json")
        with open(target, "w", encoding="utf-8") as f:
            f.write(json.dumps({"real": True}))
        path = os.path.join(self.base, "codex.json")
        os.symlink(target, path)
        self.assertIsNone(self.mod._read_json_file(path))
        with open(target, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), json.dumps({"real": True}))

    def test_fifo_does_not_block(self):
        path = os.path.join(self.base, "samples.jsonl")
        os.mkfifo(path)
        started = time.monotonic()
        text = self.mod._read_text_capped(path, 65536)
        elapsed = time.monotonic() - started
        self.assertIsNone(text)
        self.assertLess(elapsed, 2.0)

    def test_regular_file_still_reads(self):
        path = os.path.join(self.base, "codex.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps({"five_hour": {"used_percentage": 40}}))
        data = self.mod._read_json_file(path)
        self.assertEqual(data["five_hour"]["used_percentage"], 40)


class RemainingClampTests(unittest.TestCase):
    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "usage_statusline_remaining", str(SCRIPT),
        )
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def test_used_below_zero_clamps_to_full_remaining(self):
        self.assertEqual(self.mod._remaining(-10), 100.0)

    def test_used_above_hundred_clamps_to_zero_remaining(self):
        self.assertEqual(self.mod._remaining(150), 0.0)

    def test_in_range_values_unchanged_and_none_passthrough(self):
        self.assertEqual(self.mod._remaining(42), 58.0)
        self.assertEqual(self.mod._remaining(0), 100.0)
        self.assertEqual(self.mod._remaining(100), 0.0)
        self.assertIsNone(self.mod._remaining(None))


class FailedRunExclusionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.runs_dir = os.path.join(self._tmp.name, "hermes-runs")
        self.saved_runs_dir = os.environ.pop("CBOX_HERMES_DELEGATE_RUNS_DIR", None)
        os.environ["CBOX_HERMES_DELEGATE_RUNS_DIR"] = self.runs_dir
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "usage_statusline_runs", str(SCRIPT),
        )
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def tearDown(self):
        os.environ.pop("CBOX_HERMES_DELEGATE_RUNS_DIR", None)
        if self.saved_runs_dir is not None:
            os.environ["CBOX_HERMES_DELEGATE_RUNS_DIR"] = self.saved_runs_dir
        self._tmp.cleanup()

    def _write_summary(self, rid, started_epoch, ended_epoch, outcome=None):
        d = os.path.join(self.runs_dir, rid)
        os.makedirs(d, exist_ok=True)
        payload = {"started": iso(started_epoch), "ended": iso(ended_epoch)}
        if outcome is not None:
            payload["outcome"] = outcome
        with open(os.path.join(d, "summary.json"), "w", encoding="utf-8") as f:
            json.dump(payload, f)

    def test_failed_runs_excluded_from_the_median(self):
        now = time.time()
        self._write_summary(run_id(now - 3600, 1), now - 3600, now - 3600 + 300,
                            "ok")
        self._write_summary(run_id(now - 3590, 2), now - 3590, now - 3590 + 3000,
                            "error")
        self._write_summary(run_id(now - 3580, 3), now - 3580, now - 3580 + 3000,
                            "timed out")
        self._write_summary(run_id(now - 3570, 4), now - 3570, now - 3570 + 3000,
                            None)
        unfinished, durations = self.mod._hermes_run_scan()
        self.assertIsNone(unfinished)
        self.assertEqual(durations, [300.0])


if __name__ == "__main__":
    unittest.main()
