#!/usr/bin/env python3
import json
import os
import pathlib
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "etc" / "hooks" / "usage_statusline.py"


NETWORK_ENV_VARS = (
    "CBOX_USAGE_DIR",
    "CBOX_HERMES_DELEGATE_BASE_URL",
    "CBOX_HERMES_MODEL_URL",
    "CBOX_LOCAL_MODEL_URL",
)


def run(payload_text, usage_dir, extra_env=None):
    env = {
        k: v for k, v in os.environ.items()
        if k not in NETWORK_ENV_VARS
    }
    env["CBOX_USAGE_DIR"] = usage_dir
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


class UsageStatuslineTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")

    def tearDown(self):
        self._tmp.cleanup()

    def _claude_json(self):
        with open(os.path.join(self.usage_dir, "claude.json"), "r", encoding="utf-8") as f:
            return json.load(f)

    def test_valid_input_writes_file_and_prints_line(self):
        payload = json.dumps({
            "model": {"display_name": "Sonnet 5"},
            "rate_limits": {
                "five_hour": {"used_percentage": 42, "resets_at": 1000000000},
                "seven_day": {"used_percentage": 21, "resets_at": 1000000000},
            },
        })
        proc = run(payload, self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        line = proc.stdout.strip()
        self.assertIn("Sonnet 5", line)
        self.assertIn("5h 42%", line)
        self.assertIn("7d 21%", line)
        self.assertIn("pace", line)
        data = self._claude_json()
        self.assertEqual(data["source"], "claude")
        self.assertEqual(data["five_hour"]["used_percentage"], 42.0)
        self.assertEqual(data["seven_day"]["resets_at"], 1000000000.0)
        self.assertIn("captured_at", data)

    def test_file_permissions_are_locked_down(self):
        payload = json.dumps({
            "model": {"display_name": "Sonnet 5"},
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

    def test_missing_rate_limits_prints_model_only_and_skips_write(self):
        payload = json.dumps({"model": {"display_name": "Sonnet 5"}})
        proc = run(payload, self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "Sonnet 5")
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "claude.json")))

    def test_garbage_stdin_never_crashes(self):
        proc = run("not json at all {{{", self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")
        self.assertEqual(proc.stderr.strip(), "")
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "claude.json")))

    def test_empty_stdin_never_crashes(self):
        proc = run("", self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_iso_resets_at_is_accepted(self):
        payload = json.dumps({
            "model": {"display_name": "Sonnet 5"},
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
            "model": {"display_name": "Sonnet 5"},
            "rate_limits": {"five_hour": "not-a-dict", "seven_day": None},
        })
        proc = run(payload, self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "Sonnet 5")
        data = self._claude_json()
        self.assertIsNone(data["five_hour"])
        self.assertIsNone(data["seven_day"])


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
        "model": {"display_name": "Sonnet 5"},
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
            self.assertIn("hermes up", proc.stdout)
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
        self.assertIn("hermes down", proc.stdout)

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

    def test_no_hermes_url_configured_yields_unknown_state(self):
        proc = run(base_payload(), self.usage_dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "hermes.json")))
        self.assertIn("hermes ?", proc.stdout)

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


if __name__ == "__main__":
    unittest.main()
