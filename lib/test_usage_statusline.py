#!/usr/bin/env python3
import fcntl
import json
import os
import pathlib
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
    "CBOX_HERMES_DELEGATE_BASE_URL",
    "CBOX_HERMES_MODEL_URL",
    "CBOX_LOCAL_MODEL_URL",
    "CBOX_CODEX_USAGE_REFRESH",
    "CBOX_HERMES_DELEGATE_LOCK_DIR",
    "CBOX_HERMES_DELEGATE_RUNS_DIR",
    "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY",
    "OLLAMA_NUM_PARALLEL",
    "CBOX_PROFILE",
    "COLUMNS",
    "NO_COLOR",
)


def run(payload_text, usage_dir, extra_env=None):
    env = {
        k: v for k, v in os.environ.items()
        if k not in NETWORK_ENV_VARS
    }
    env["CBOX_USAGE_DIR"] = usage_dir
    env["CBOX_CODEX_USAGE_REFRESH"] = "off"
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
        self.assertIn("claude: 58%(0m)/79%(0h)", line)
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

    def test_past_resets_at_clamps_to_zero_not_negative(self):
        self.assertEqual(self.mod._reset_countdown(-100, 0, "five_hour"), "(0m)")
        self.assertEqual(self.mod._reset_countdown(-100, 0, "seven_day"), "(0h)")


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
