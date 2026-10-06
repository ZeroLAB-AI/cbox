#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
REFRESH_SCRIPT = ROOT / "etc" / "hooks" / "codex_usage_refresh.py"
SHIM_SCRIPT = ROOT / "etc" / "mcp" / "codex_mcp_shim.py"
GUARD_SCRIPT = ROOT / "etc" / "hooks" / "codex_mode_guard.py"


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class RefreshHarness(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "cbox-usage")
        self.codex_home = os.path.join(self._tmp.name, "codex-home")
        os.makedirs(self.codex_home, exist_ok=True)
        self.saved_usage_dir = os.environ.pop("CBOX_USAGE_DIR", None)
        self.saved_codex_home = os.environ.pop("CODEX_HOME", None)
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir
        os.environ["CODEX_HOME"] = self.codex_home
        self.mod = load_module(REFRESH_SCRIPT, "codex_usage_refresh_test_%s" % id(self))
        self.shim = load_module(SHIM_SCRIPT, "codex_mcp_shim_test_%s" % id(self))

    def tearDown(self):
        os.environ.pop("CBOX_USAGE_DIR", None)
        os.environ.pop("CODEX_HOME", None)
        if self.saved_usage_dir is not None:
            os.environ["CBOX_USAGE_DIR"] = self.saved_usage_dir
        if self.saved_codex_home is not None:
            os.environ["CODEX_HOME"] = self.saved_codex_home
        self._tmp.cleanup()

    def _write_auth(self, content="{}"):
        with open(os.path.join(self.codex_home, "auth.json"), "w", encoding="utf-8") as f:
            f.write(content)

    def _codex_json(self):
        path = os.path.join(self.usage_dir, "codex.json")
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)


class AuthAndInstallGateTests(RefreshHarness):
    def test_missing_codex_binary_skips_silently(self):
        self._write_auth()
        with mock.patch.object(self.mod.shutil, "which", return_value=None):
            rc = self.mod.main()
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "codex.json")))

    def test_missing_auth_skips_silently(self):
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"):
            rc = self.mod.main()
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "codex.json")))

    def test_empty_auth_file_treated_as_not_logged_in(self):
        self._write_auth(content="")
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"):
            rc = self.mod.main()
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "codex.json")))


class ShimLocationTests(RefreshHarness):
    def _deploy(self, layout):
        root = os.path.join(self._tmp.name, "deploy-" + layout)
        hooks = os.path.join(root, "hooks")
        os.makedirs(hooks)
        shim_dir = hooks if layout == "flat" else os.path.join(root, "mcp")
        os.makedirs(shim_dir, exist_ok=True)
        with open(REFRESH_SCRIPT, "rb") as src, open(os.path.join(hooks, "codex_usage_refresh.py"), "wb") as dst:
            dst.write(src.read())
        with open(SHIM_SCRIPT, "rb") as src, open(os.path.join(shim_dir, "codex_mcp_shim.py"), "wb") as dst:
            dst.write(src.read())
        with open(GUARD_SCRIPT, "rb") as src, open(os.path.join(hooks, "codex_mode_guard.py"), "wb") as dst:
            dst.write(src.read())
        return load_module(os.path.join(hooks, "codex_usage_refresh.py"), "codex_usage_refresh_%s_%s" % (layout, id(self)))

    def test_flat_deployed_layout_finds_sibling_shim(self):
        mod = self._deploy("flat")
        shim = mod._load_shim()
        self.assertTrue(callable(shim.write_codex_usage_snapshot))

    def test_repo_layout_finds_mcp_shim(self):
        mod = self._deploy("repo")
        shim = mod._load_shim()
        self.assertTrue(callable(shim.write_codex_usage_snapshot))

    def test_flat_layout_main_writes_snapshot(self):
        mod = self._deploy("flat")
        self._write_auth()
        probe = {"rateLimits": {"primary": {"usedPercent": 4, "windowDurationMins": 300, "resetsAt": int(time.time()) + 3600}}, "ordinaryUsageAllowed": True}
        with mock.patch.object(mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(mod, "_run_probe", return_value=probe):
            rc = mod.main()
        self.assertEqual(rc, 0)
        self.assertEqual(self._codex_json()["five_hour"]["used_percentage"], 4)


class ProbeCaptureTests(RefreshHarness):
    def test_successful_probe_writes_codex_json_via_shim_writer(self):
        self._write_auth()
        probe = {
            "rateLimits": {
                "primary": {"usedPercent": 20, "resetsAt": 1790340325, "windowDurationMins": 300},
                "secondary": {"usedPercent": 5, "resetsAt": 1790842078, "windowDurationMins": 10080},
                "planType": "plus",
            },
            "ordinaryUsageAllowed": True,
        }
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod, "_run_probe", return_value=probe):
            rc = self.mod.main()
        self.assertEqual(rc, 0)
        data = self._codex_json()
        self.assertEqual(data["source"], "codex")
        self.assertEqual(data["five_hour"]["used_percentage"], 20)
        self.assertEqual(data["seven_day"]["used_percentage"], 5)
        self.assertEqual(data["ordinary_usage_allowed"], True)

    def test_successful_probe_captures_reached_fields_when_limit_hit(self):
        self._write_auth()
        probe = {
            "rateLimits": {
                "primary": {"usedPercent": 100, "resetsAt": 1790340325, "windowDurationMins": 300},
                "secondary": {"usedPercent": 44, "resetsAt": 1790842078, "windowDurationMins": 10080},
                "planType": "plus",
                "rateLimitReachedType": "rate_limit_reached",
            },
            "ordinaryUsageAllowed": False,
        }
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod, "_run_probe", return_value=probe):
            rc = self.mod.main()
        self.assertEqual(rc, 0)
        data = self._codex_json()
        self.assertEqual(data["rate_limit_reached_type"], "rate_limit_reached")
        self.assertEqual(data["ordinary_usage_allowed"], False)

    def test_failed_probe_never_raises_and_leaves_no_file(self):
        self._write_auth()
        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod, "_run_probe", return_value=None):
            rc = self.mod.main()
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "codex.json")))

    def test_probe_exception_is_swallowed(self):
        self._write_auth()

        def boom():
            raise RuntimeError("stub induced failure")

        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod, "_run_probe", side_effect=boom):
            rc = self.mod.main()
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "codex.json")))


class SingleFlightLockTests(RefreshHarness):
    def test_second_acquire_is_refused_while_first_is_held(self):
        handle1 = self.mod._acquire_lock(self.shim)
        self.assertIsNotNone(handle1)
        handle2 = self.mod._acquire_lock(self.shim)
        self.assertIsNone(handle2)
        self.mod._release_lock(handle1)

    def test_acquire_succeeds_again_after_release(self):
        handle1 = self.mod._acquire_lock(self.shim)
        self.assertIsNotNone(handle1)
        self.mod._release_lock(handle1)
        handle2 = self.mod._acquire_lock(self.shim)
        self.assertIsNotNone(handle2)
        self.mod._release_lock(handle2)

    def test_full_run_holds_the_lock_so_a_concurrent_run_is_skipped(self):
        self._write_auth()
        import threading
        gate = threading.Event()
        entered = threading.Event()

        def slow_probe():
            entered.set()
            gate.wait(2)
            return {"rateLimits": {"primary": {"usedPercent": 1, "resetsAt": 1}}}

        with mock.patch.object(self.mod.shutil, "which", return_value="/usr/bin/codex"), \
                mock.patch.object(self.mod, "_run_probe", side_effect=slow_probe):
            t = threading.Thread(target=self.mod.main)
            t.start()
            entered.wait(2)
            second_rc = self.mod.main()
            self.assertEqual(second_rc, 0)
            self.assertFalse(os.path.exists(os.path.join(self.usage_dir, "codex.json")))
            gate.set()
            t.join(timeout=3)
        data = self._codex_json()
        self.assertEqual(data["five_hour"]["used_percentage"], 1)


class TimeoutBudgetTests(RefreshHarness):
    def test_init_plus_read_fits_inside_overall_timeout(self):
        self.assertLessEqual(
            self.mod.INIT_TIMEOUT_SEC + self.mod.RATE_LIMIT_READ_TIMEOUT_SEC,
            self.mod.OVERALL_TIMEOUT_SEC - 3,
        )


if __name__ == "__main__":
    unittest.main()
