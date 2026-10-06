#!/usr/bin/env python3
import importlib.util
import json
import math
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "etc" / "hooks" / "cbox_budget.py"

spec = importlib.util.spec_from_file_location("cbox_budget", str(SCRIPT))
cbox_budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cbox_budget)


def write_source(usage_dir, name, payload):
    os.makedirs(usage_dir, exist_ok=True)
    with open(os.path.join(usage_dir, "%s.json" % name), "w", encoding="utf-8") as f:
        json.dump(payload, f)


class PaceMathTests(unittest.TestCase):
    def test_pace_at_start_of_week_is_floored(self):
        now = 1000000000.0
        resets = now + 7 * 24 * 3600
        frac = cbox_budget.elapsed_fraction(resets, cbox_budget.WINDOW_SECONDS["seven_day"], now)
        self.assertAlmostEqual(frac, 0.05)
        p = cbox_budget.pace(5.0, frac)
        self.assertAlmostEqual(p, 1.0)

    def test_pace_at_midweek_on_track(self):
        now = 1000000000.0
        window = cbox_budget.WINDOW_SECONDS["seven_day"]
        resets = now + window / 2.0
        frac = cbox_budget.elapsed_fraction(resets, window, now)
        self.assertAlmostEqual(frac, 0.5)
        p = cbox_budget.pace(50.0, frac)
        self.assertAlmostEqual(p, 1.0)

    def test_pace_ahead_of_schedule(self):
        now = 1000000000.0
        window = cbox_budget.WINDOW_SECONDS["seven_day"]
        resets = now + window * 0.9
        frac = cbox_budget.elapsed_fraction(resets, window, now)
        self.assertAlmostEqual(frac, 0.1)
        p = cbox_budget.pace(30.0, frac)
        self.assertAlmostEqual(p, 3.0)

    def test_pace_none_when_inputs_missing(self):
        self.assertIsNone(cbox_budget.pace(None, 0.5))
        self.assertIsNone(cbox_budget.pace(10.0, None))

    def test_elapsed_fraction_none_when_resets_missing(self):
        self.assertIsNone(cbox_budget.elapsed_fraction(None, 3600, 100.0))

    def test_parse_resets_at_epoch_and_iso(self):
        self.assertEqual(cbox_budget.parse_resets_at(1700000000), 1700000000.0)
        epoch = cbox_budget.parse_resets_at("2023-11-14T22:13:20+00:00")
        self.assertAlmostEqual(epoch, 1700000000.0, delta=1)
        z_epoch = cbox_budget.parse_resets_at("2023-11-14T22:13:20Z")
        self.assertAlmostEqual(z_epoch, 1700000000.0, delta=1)
        self.assertIsNone(cbox_budget.parse_resets_at("not-a-date"))
        self.assertIsNone(cbox_budget.parse_resets_at(None))

    def test_roll_window_exact_and_multiple_periods(self):
        self.assertEqual(cbox_budget.roll_window(95, 1000, 1000, 18000), (0.0, 19000))
        self.assertEqual(cbox_budget.roll_window(95, 1000, 37000, 18000), (0.0, 55000))
        self.assertEqual(cbox_budget.roll_window(95, None, 37000, 18000), (95, None))


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._env_patch = {"CBOX_USAGE_DIR": self.usage_dir}
        self._old_env = {k: os.environ.get(k) for k in self._env_patch}
        os.environ.update(self._env_patch)

    def tearDown(self):
        for k, v in self._old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self._tmp.cleanup()

    def test_missing_source_is_omitted(self):
        m = cbox_budget.metrics(now=1000.0)
        self.assertEqual(m, {})

    def test_malformed_source_is_omitted(self):
        with open(os.path.join(self.usage_dir, "claude.json"), "w", encoding="utf-8") as f:
            f.write("{not json")
        m = cbox_budget.metrics(now=1000.0)
        self.assertNotIn("claude", m)

    def test_source_without_captured_at_is_omitted(self):
        write_source(self.usage_dir, "claude", {"five_hour": {"used_percentage": 1}})
        m = cbox_budget.metrics(now=1000.0)
        self.assertNotIn("claude", m)

    def test_fresh_source_metrics_shape(self):
        now = 1000000000.0
        window = cbox_budget.WINDOW_SECONDS["seven_day"]
        resets = now + window * 0.5
        write_source(self.usage_dir, "claude", {
            "captured_at": now - 60,
            "five_hour": {"used_percentage": 10, "resets_at": now + 3600},
            "seven_day": {"used_percentage": 50, "resets_at": resets},
        })
        m = cbox_budget.metrics(now=now)
        self.assertIn("claude", m)
        c = m["claude"]
        self.assertFalse(c["stale"])
        self.assertAlmostEqual(c["age_seconds"], 60)
        self.assertAlmostEqual(c["seven_day"]["pace"], 1.0)
        self.assertAlmostEqual(c["seven_day"]["elapsed_fraction"], 0.5)

    def test_stale_after_two_hours(self):
        now = 1000000000.0
        write_source(self.usage_dir, "claude", {
            "captured_at": now - 7201,
            "seven_day": {"used_percentage": 5, "resets_at": now + 1000},
        })
        m = cbox_budget.metrics(now=now)
        self.assertTrue(m["claude"]["stale"])

    def test_not_stale_at_exactly_two_hours_boundary(self):
        now = 1000000000.0
        write_source(self.usage_dir, "claude", {
            "captured_at": now - 7200,
            "seven_day": {"used_percentage": 5, "resets_at": now + 1000},
        })
        m = cbox_budget.metrics(now=now)
        self.assertFalse(m["claude"]["stale"])

    def test_codex_source_is_read_independently(self):
        now = 1000000000.0
        write_source(self.usage_dir, "codex", {
            "captured_at": now - 5,
            "five_hour": {"used_percentage": 30, "resets_at": now + 100},
        })
        m = cbox_budget.metrics(now=now)
        self.assertIn("codex", m)
        self.assertNotIn("claude", m)

    def test_cli_metrics_prints_json(self):
        now_write = {
            "captured_at": 1000000000.0 - 10,
            "seven_day": {"used_percentage": 5, "resets_at": 1000000000.0 + 1000},
        }
        write_source(self.usage_dir, "claude", now_write)
        env = dict(os.environ)
        proc = subprocess.run(
            ["python3", str(SCRIPT), "metrics"],
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertIn("claude", payload)

    def test_cli_unknown_subcommand_exits_nonzero(self):
        proc = subprocess.run(
            ["python3", str(SCRIPT), "mode"],
            capture_output=True, text=True, env=dict(os.environ),
        )
        self.assertNotEqual(proc.returncode, 0)


def _epoch(y, m, d, hh=0, mm=0):
    import datetime
    return datetime.datetime(y, m, d, hh, mm, tzinfo=datetime.timezone.utc).timestamp()


class ActiveHoursTests(unittest.TestCase):
    def test_a_full_week_sums_to_the_weekly_total_regardless_of_alignment(self):
        total = sum(cbox_budget.ACTIVE_HOURS_PROFILE)
        for start_day in range(1, 8):
            start = _epoch(2026, 10, start_day, 13, 17)
            end = start + 7 * 24 * 3600
            got = cbox_budget.active_hours_between(start, end)
            self.assertAlmostEqual(got, total, places=6)

    def test_a_partial_day_is_prorated_by_the_16_hour_window(self):
        start = _epoch(2026, 10, 1, 18, 0)
        end = _epoch(2026, 10, 1, 22, 0)
        got = cbox_budget.active_hours_between(start, end)
        expected = cbox_budget.ACTIVE_HOURS_PROFILE[3] * (4.0 / 16.0)
        self.assertAlmostEqual(got, expected, places=6)

    def test_outside_the_daily_window_contributes_nothing(self):
        start = _epoch(2026, 10, 1, 23, 0)
        end = _epoch(2026, 10, 2, 6, 0)
        self.assertAlmostEqual(cbox_budget.active_hours_between(start, end), 0.0, places=6)

    def test_end_before_start_is_zero(self):
        self.assertEqual(cbox_budget.active_hours_between(2000.0, 1000.0), 0.0)


class CostPriorTests(unittest.TestCase):
    def setUp(self):
        self._old = {}
        for k in list(os.environ):
            if k.startswith("CBOX_BUDGET_COST_"):
                self._old[k] = os.environ.pop(k)

    def tearDown(self):
        for k in list(os.environ):
            if k.startswith("CBOX_BUDGET_COST_") and k not in self._old:
                os.environ.pop(k, None)
        os.environ.update(self._old)

    def test_priors_match_the_spec_table(self):
        self.assertEqual(cbox_budget._cost_prior("claude", "seven_day"), 1.5)
        self.assertEqual(cbox_budget._cost_prior("claude", "five_hour"), 6.0)
        self.assertEqual(cbox_budget._cost_prior("codex", "seven_day"), 14.0)
        self.assertEqual(cbox_budget._cost_prior("codex", "five_hour"), 115.0)

    def test_env_override_wins(self):
        os.environ["CBOX_BUDGET_COST_CLAUDE_SEVEN_DAY"] = "9.5"
        self.assertEqual(cbox_budget._cost_prior("claude", "seven_day"), 9.5)

    def test_malformed_override_falls_back_to_prior(self):
        os.environ["CBOX_BUDGET_COST_CLAUDE_FIVE_HOUR"] = "not-a-number"
        self.assertEqual(cbox_budget._cost_prior("claude", "five_hour"), 6.0)


class DriverReserveTests(unittest.TestCase):
    def test_claude_reserve_floors_at_8(self):
        self.assertEqual(cbox_budget._driver_reserve("claude", 10.0), 8.0)

    def test_claude_reserve_scales_above_the_floor(self):
        self.assertAlmostEqual(cbox_budget._driver_reserve("claude", 66.0), 23.1, places=6)

    def test_codex_reserve_is_always_zero(self):
        self.assertEqual(cbox_budget._driver_reserve("codex", 66.0), 0.0)


class FixtureBudgetTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def test_thursday_evening_seven_day_34_percent(self):
        now = _epoch(2026, 10, 1, 18, 0)
        resets = _epoch(2026, 10, 4, 0, 0)
        write_source(self.usage_dir, "claude", {
            "captured_at": now,
            "seven_day": {"used_percentage": 34, "resets_at": resets},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        h = cbox_budget.active_hours_between(now, resets)
        q, d = 66.0, cbox_budget._driver_reserve("claude", 66.0)
        expected = min(cbox_budget.CONCURRENCY_CAP_P, (q - d) / (1.5 * max(h, cbox_budget.H_FLOOR_HOURS)))
        print("fixture thursday_18h_seven_day_34pct: H=%.3f expected=%.3f got=%.3f" % (h, expected, result["b"]))
        self.assertAlmostEqual(result["b"], expected, places=6)
        self.assertTrue(2.0 <= result["b"] <= 3.0, "B should sit near the 'around 2.5' owner estimate, got %.3f" % result["b"])

    def test_monday_morning_seven_day_40_with_binding_five_hour_85(self):
        now = _epoch(2026, 10, 5, 9, 0)
        seven_resets = _epoch(2026, 10, 11, 0, 0)
        five_resets = now + 2 * 3600
        write_source(self.usage_dir, "claude", {
            "captured_at": now,
            "five_hour": {"used_percentage": 85, "resets_at": five_resets},
            "seven_day": {"used_percentage": 40, "resets_at": seven_resets},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        h5 = (five_resets - now) / 3600.0
        q5, d5 = 15.0, cbox_budget._driver_reserve("claude", 15.0)
        val5 = min(cbox_budget.CONCURRENCY_CAP_P, (q5 - d5) / (6.0 * max(h5, cbox_budget.H_FLOOR_HOURS)))
        h7 = cbox_budget.active_hours_between(now, seven_resets)
        q7, d7 = 60.0, cbox_budget._driver_reserve("claude", 60.0)
        val7 = min(cbox_budget.CONCURRENCY_CAP_P, (q7 - d7) / (1.5 * max(h7, cbox_budget.H_FLOOR_HOURS)))
        expected = min(val5, val7)
        print("fixture monday_09h_seven_day_40_five_hour_85: five=%.3f seven=%.3f expected=%.3f got=%.3f"
              % (val5, val7, expected, result["b"]))
        self.assertAlmostEqual(result["b"], expected, places=6)
        self.assertAlmostEqual(result["b"], val5, places=6, msg="the five-hour window should be the binding one")
        self.assertEqual(result["resets_at"], five_resets)

    def test_last_24h_with_20_percent_left(self):
        resets = _epoch(2026, 10, 4, 0, 0)
        now = resets - 24 * 3600
        write_source(self.usage_dir, "claude", {
            "captured_at": now,
            "seven_day": {"used_percentage": 80, "resets_at": resets},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        h = cbox_budget.active_hours_between(now, resets)
        q, d = 20.0, cbox_budget._driver_reserve("claude", 20.0)
        expected = min(cbox_budget.CONCURRENCY_CAP_P, (q - d) / (1.5 * max(h, cbox_budget.H_FLOOR_HOURS)))
        print("fixture last_24h_20pct_left: H=%.3f expected=%.3f got=%.3f" % (h, expected, result["b"]))
        self.assertAlmostEqual(result["b"], expected, places=6)

    def test_near_reset_has_no_taper(self):
        now = _epoch(2026, 10, 1, 12, 0)
        resets = now + 600
        write_source(self.usage_dir, "claude", {
            "captured_at": now,
            "five_hour": {"used_percentage": 10, "resets_at": resets},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertAlmostEqual(result["b"], cbox_budget.CONCURRENCY_CAP_P, places=3)
        self.assertEqual(cbox_budget._driver_reserve("claude", 90, 0, "five_hour"), 0)
        self.assertAlmostEqual(cbox_budget._driver_reserve("claude", 90, 0.25, "five_hour"), 2)

    def test_taper_is_not_binding_far_from_reset(self):
        now = _epoch(2026, 10, 1, 12, 0)
        resets = now + 3600
        write_source(self.usage_dir, "claude", {
            "captured_at": now,
            "five_hour": {"used_percentage": 10, "resets_at": resets},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertAlmostEqual(result["b"], cbox_budget.CONCURRENCY_CAP_P, places=3)


class StalenessAndUnknownTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def test_missing_data_is_unknown(self):
        result = cbox_budget.budget_for_family("claude")
        self.assertEqual(result["status"], "unknown")
        self.assertIsNone(result["b"])

    def test_five_hour_older_than_15_minutes_is_excluded_but_seven_day_still_counts(self):
        now = 1700000000.0
        write_source(self.usage_dir, "claude", {
            "captured_at": now - 901,
            "five_hour": {"used_percentage": 50, "resets_at": now + 3600},
            "seven_day": {"used_percentage": 10, "resets_at": now + 6 * 24 * 3600},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["status"], "ok")
        self.assertIsNotNone(result["b"])

    def test_data_older_than_2_hours_is_fully_unknown(self):
        now = 1700000000.0
        write_source(self.usage_dir, "claude", {
            "captured_at": now - 7201,
            "seven_day": {"used_percentage": 10, "resets_at": now + 6 * 24 * 3600},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["status"], "unknown")
        self.assertIsNone(result["b"])

    def test_mode_off_disables_everything(self):
        old = os.environ.get("CBOX_BUDGET_MODE")
        os.environ["CBOX_BUDGET_MODE"] = "off"
        try:
            now = 1700000000.0
            write_source(self.usage_dir, "claude", {
                "captured_at": now,
                "seven_day": {"used_percentage": 10, "resets_at": now + 6 * 24 * 3600},
            })
            result = cbox_budget.budget_for_family("claude", now=now)
            self.assertEqual(result["status"], "off")
            self.assertIsNone(result["b"])
        finally:
            if old is None:
                os.environ.pop("CBOX_BUDGET_MODE", None)
            else:
                os.environ["CBOX_BUDGET_MODE"] = old


class OverrideTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def _write_override(self, until, b):
        with open(os.path.join(self.usage_dir, "override.json"), "w", encoding="utf-8") as f:
            json.dump({"until": until, "b": b}, f)

    def test_override_forces_b_while_active(self):
        now = 1700000000.0
        self._write_override(now + 60, 2.5)
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["status"], "override")
        self.assertEqual(result["b"], 2.5)

    def test_override_expires(self):
        now = 1700000000.0
        self._write_override(now - 1, 2.5)
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertNotEqual(result["status"], "override")


class HysteresisTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def test_cold_start_takes_the_ceiling_directly(self):
        n = cbox_budget.apply_hysteresis("claude", 1.4, now=1000.0)
        self.assertEqual(n, 2)

    def test_small_moves_inside_the_band_do_not_change_n(self):
        cbox_budget.apply_hysteresis("claude", 2.0, now=1000.0)
        n = cbox_budget.apply_hysteresis("claude", 2.19, now=1001.0)
        self.assertEqual(n, 2)
        n = cbox_budget.apply_hysteresis("claude", 0.81, now=1002.0)
        self.assertEqual(n, 2)

    def test_crossing_the_up_threshold_raises_n(self):
        cbox_budget.apply_hysteresis("claude", 2.0, now=1000.0)
        n = cbox_budget.apply_hysteresis("claude", 2.2, now=1001.0)
        self.assertEqual(n, 3)

    def test_crossing_the_down_threshold_lowers_n(self):
        cbox_budget.apply_hysteresis("claude", 2.0, now=1000.0)
        n = cbox_budget.apply_hysteresis("claude", 0.8, now=1001.0)
        self.assertEqual(n, 1)

    def test_unknown_b_keeps_the_previous_n(self):
        cbox_budget.apply_hysteresis("claude", 2.0, now=1000.0)
        n = cbox_budget.apply_hysteresis("claude", None, now=1001.0)
        self.assertEqual(n, 2)

    def test_families_are_independent(self):
        cbox_budget.apply_hysteresis("claude", 2.0, now=1000.0)
        n = cbox_budget.apply_hysteresis("codex", 0.1, now=1000.0)
        self.assertEqual(n, 1)


class HermesStateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def _write(self, payload):
        with open(os.path.join(self.usage_dir, "hermes.json"), "w", encoding="utf-8") as f:
            json.dump(payload, f)

    def test_missing_file_is_unknown(self):
        self.assertEqual(cbox_budget.hermes_state()["state"], "unknown")

    def test_recent_reachable_is_available(self):
        now = 1700000000.0
        self._write({"ts": now, "last_probe_ts": now, "reachable": True,
                     "model_loaded": True, "history": [True, True]})
        self.assertEqual(cbox_budget.hermes_state(now=now + 5)["state"], "available")

    def test_recent_unreachable_is_unavailable(self):
        now = 1700000000.0
        self._write({"ts": now, "last_probe_ts": now, "reachable": False,
                     "model_loaded": False, "history": [False, False]})
        self.assertEqual(cbox_budget.hermes_state(now=now + 5)["state"], "unavailable")

    def test_a_single_recent_success_within_the_last_two_checks_counts_as_available(self):
        now = 1700000000.0
        self._write({"ts": now, "last_probe_ts": now, "reachable": False,
                     "model_loaded": False, "history": [True, False]})
        self.assertEqual(cbox_budget.hermes_state(now=now + 5)["state"], "available")

    def test_older_than_two_minutes_is_unknown(self):
        now = 1700000000.0
        self._write({"ts": now, "last_probe_ts": now, "reachable": True,
                     "model_loaded": True, "history": [True, True]})
        self.assertEqual(cbox_budget.hermes_state(now=now + 121)["state"], "unknown")


class BudgetCliTests(unittest.TestCase):
    def test_cli_budget_prints_json_for_all_families(self):
        with tempfile.TemporaryDirectory() as usage_dir:
            import time as _time
            now = _time.time()
            write_source(usage_dir, "claude", {
                "captured_at": now,
                "seven_day": {"used_percentage": 10, "resets_at": now + 6 * 24 * 3600},
            })
            env = dict(os.environ)
            env["CBOX_USAGE_DIR"] = usage_dir
            proc = subprocess.run(["python3", str(SCRIPT), "budget"],
                                   capture_output=True, text=True, env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            payload = json.loads(proc.stdout)
            self.assertIn("claude", payload)
            self.assertEqual(payload["claude"]["status"], "ok")

    def test_cli_budget_accepts_a_single_family(self):
        with tempfile.TemporaryDirectory() as usage_dir:
            env = dict(os.environ)
            env["CBOX_USAGE_DIR"] = usage_dir
            proc = subprocess.run(["python3", str(SCRIPT), "budget", "claude"],
                                   capture_output=True, text=True, env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            payload = json.loads(proc.stdout)
            self.assertEqual(list(payload.keys()), ["claude"])


class NumberValidationTests(unittest.TestCase):
    def test_infinite_and_nan_numbers_are_rejected(self):
        self.assertIsNone(cbox_budget._num(float("inf")))
        self.assertIsNone(cbox_budget._num(float("-inf")))
        self.assertIsNone(cbox_budget._num(float("nan")))

    def test_finite_numbers_pass_through(self):
        self.assertEqual(cbox_budget._num(3), 3.0)
        self.assertEqual(cbox_budget._num(2.5), 2.5)


class OverrideValidationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def _write_override(self, until, b):
        with open(os.path.join(self.usage_dir, "override.json"), "w", encoding="utf-8") as f:
            json.dump({"until": until, "b": b}, f)

    def test_until_more_than_24h_out_is_ignored(self):
        now = 1700000000.0
        self._write_override(now + 25 * 3600, 2.0)
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertNotEqual(result["status"], "override")

    def test_until_exactly_24h_out_is_accepted(self):
        now = 1700000000.0
        self._write_override(now + 24 * 3600, 2.0)
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["status"], "override")

    def test_b_above_3_is_clamped(self):
        now = 1700000000.0
        self._write_override(now + 60, 50.0)
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["b"], 3.0)

    def test_b_below_0_is_clamped(self):
        now = 1700000000.0
        self._write_override(now + 60, -5.0)
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["b"], 0.0)

    def test_override_until_is_exposed_on_the_result(self):
        now = 1700000000.0
        self._write_override(now + 60, 2.5)
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["override_until"], now + 60)


class CapturedAtFutureTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def test_captured_at_more_than_60s_in_the_future_is_unknown(self):
        now = 1700000000.0
        write_source(self.usage_dir, "claude", {
            "captured_at": now + 120,
            "seven_day": {"used_percentage": 10, "resets_at": now + 6 * 24 * 3600},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["status"], "unknown")
        self.assertIsNone(result["b"])

    def test_captured_at_within_60s_in_the_future_is_ok(self):
        now = 1700000000.0
        write_source(self.usage_dir, "claude", {
            "captured_at": now + 30,
            "seven_day": {"used_percentage": 10, "resets_at": now + 6 * 24 * 3600},
        })
        result = cbox_budget.budget_for_family("claude", now=now)
        self.assertEqual(result["status"], "ok")


class ResetsAtClampTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def test_resets_at_far_beyond_the_window_is_clamped_to_now_plus_window(self):
        now = 1000000000.0
        write_source(self.usage_dir, "claude", {
            "captured_at": now - 10,
            "five_hour": {"used_percentage": 10, "resets_at": now + 100 * 3600},
        })
        m = cbox_budget.metrics(now=now)
        self.assertAlmostEqual(m["claude"]["five_hour"]["resets_at"], now + 5 * 3600)

    def test_resets_at_in_the_past_rolls_forward(self):
        now = 1000000000.0
        write_source(self.usage_dir, "claude", {
            "captured_at": now - 10,
            "five_hour": {"used_percentage": 10, "resets_at": now - 1000},
        })
        m = cbox_budget.metrics(now=now)
        self.assertAlmostEqual(m["claude"]["five_hour"]["resets_at"], now + 17000)
        self.assertEqual(m["claude"]["five_hour"]["used_percentage"], 0)
        self.assertGreater(cbox_budget.budget_for_family("claude", now=now)["b"], 0)


class StateNValidationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = self._tmp.name
        self._old = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        if self._old is None:
            os.environ.pop("CBOX_USAGE_DIR", None)
        else:
            os.environ["CBOX_USAGE_DIR"] = self._old
        self._tmp.cleanup()

    def _write_state(self, n):
        path = cbox_budget._state_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"claude": {"n": n, "b": 1.0, "ts": 900.0}}, f)

    def test_non_integer_n_is_a_cold_start(self):
        self._write_state("bogus")
        n = cbox_budget.apply_hysteresis("claude", 1.4, now=1000.0)
        self.assertEqual(n, 2)

    def test_out_of_range_n_is_a_cold_start(self):
        self._write_state(99)
        n = cbox_budget.apply_hysteresis("claude", 1.4, now=1000.0)
        self.assertEqual(n, 2)

    def test_bool_n_is_a_cold_start(self):
        self._write_state(True)
        n = cbox_budget.apply_hysteresis("claude", 1.4, now=1000.0)
        self.assertEqual(n, 2)

    def test_float_n_is_a_cold_start(self):
        self._write_state(2.5)
        n = cbox_budget.apply_hysteresis("claude", 1.4, now=1000.0)
        self.assertEqual(n, 2)


class CostPriorInvalidOverrideTests(unittest.TestCase):
    def setUp(self):
        self._old = {}
        for k in list(os.environ):
            if k.startswith("CBOX_BUDGET_COST_"):
                self._old[k] = os.environ.pop(k)

    def tearDown(self):
        for k in list(os.environ):
            if k.startswith("CBOX_BUDGET_COST_") and k not in self._old:
                os.environ.pop(k, None)
        os.environ.update(self._old)

    def test_negative_override_falls_back_to_prior(self):
        os.environ["CBOX_BUDGET_COST_CLAUDE_FIVE_HOUR"] = "-5"
        self.assertEqual(cbox_budget._cost_prior("claude", "five_hour"), 6.0)

    def test_zero_override_falls_back_to_prior(self):
        os.environ["CBOX_BUDGET_COST_CLAUDE_FIVE_HOUR"] = "0"
        self.assertEqual(cbox_budget._cost_prior("claude", "five_hour"), 6.0)

    def test_infinite_override_falls_back_to_prior(self):
        os.environ["CBOX_BUDGET_COST_CLAUDE_FIVE_HOUR"] = "inf"
        self.assertEqual(cbox_budget._cost_prior("claude", "five_hour"), 6.0)

    def test_nan_override_falls_back_to_prior(self):
        os.environ["CBOX_BUDGET_COST_CLAUDE_FIVE_HOUR"] = "nan"
        self.assertEqual(cbox_budget._cost_prior("claude", "five_hour"), 6.0)


class ActiveHoursClampTests(unittest.TestCase):
    def test_a_range_beyond_8_days_is_clamped(self):
        start = _epoch(2026, 10, 1, 0, 0)
        long_end = start + 30 * 24 * 3600
        clamped_end = start + 8 * 24 * 3600
        got_long = cbox_budget.active_hours_between(start, long_end)
        got_clamped = cbox_budget.active_hours_between(start, clamped_end)
        self.assertAlmostEqual(got_long, got_clamped, places=6)


class SafeReadTests(unittest.TestCase):
    def test_symlinked_file_is_refused(self):
        d = tempfile.mkdtemp()
        target = os.path.join(d, "target.json")
        with open(target, "w", encoding="utf-8") as f:
            f.write("{}")
        link = os.path.join(d, "link.json")
        os.symlink(target, link)
        self.assertIsNone(cbox_budget.safe_read_json(link))

    def test_missing_file_returns_none(self):
        d = tempfile.mkdtemp()
        self.assertIsNone(cbox_budget.safe_read_json(os.path.join(d, "nope.json")))

    def test_fifo_is_refused(self):
        d = tempfile.mkdtemp()
        fifo = os.path.join(d, "pipe")
        os.mkfifo(fifo)
        self.assertIsNone(cbox_budget.safe_read_bytes(fifo))

    def test_read_is_capped(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "big.json")
        with open(path, "wb") as f:
            f.write(b"a" * 70000)
        raw = cbox_budget.safe_read_bytes(path, cap=65536)
        self.assertEqual(len(raw), 65536)


class ClaudeSnapshotHarness(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.usage_dir = os.path.join(self._tmp.name, "usage")
        os.makedirs(self.usage_dir)
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in list(os.environ):
            if name.startswith("CBOX_") or name in ("CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"):
                os.environ.pop(name)
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir

    def tearDown(self):
        self._tmp.cleanup()

    def snap_path(self):
        return os.path.join(self.usage_dir, "claude.json")

    def snap(self):
        with open(self.snap_path(), "r", encoding="utf-8") as f:
            return json.load(f)


def win(used, resets, captured):
    return {"used_percentage": used, "resets_at": resets, "captured_at": captured}


NOW_T = 1800000000.0


class PerWindowStalenessTests(ClaudeSnapshotHarness):
    def test_each_window_is_judged_by_its_own_captured_at(self):
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T,
            "five_hour": win(10, NOW_T + 3600, NOW_T - 2000),
            "seven_day": win(10, NOW_T + 6 * 24 * 3600, NOW_T),
        })
        m = cbox_budget.source_metrics("claude", NOW_T)
        self.assertEqual(m["five_hour"]["captured_at"], NOW_T - 2000)
        self.assertAlmostEqual(m["five_hour"]["age_seconds"], 2000)
        self.assertAlmostEqual(m["seven_day"]["age_seconds"], 0)
        result = cbox_budget.budget_for_family("claude", now=NOW_T)
        self.assertEqual(result["status"], "ok")

    def test_old_five_hour_stamp_excludes_only_that_window(self):
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T,
            "five_hour": win(99, NOW_T + 3600, NOW_T - 901),
            "seven_day": win(10, NOW_T + 6 * 24 * 3600, NOW_T),
        })
        fresh_only = cbox_budget.budget_for_family("claude", now=NOW_T)
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T,
            "seven_day": win(10, NOW_T + 6 * 24 * 3600, NOW_T),
        })
        seven_only = cbox_budget.budget_for_family("claude", now=NOW_T)
        self.assertEqual(fresh_only["b"], seven_only["b"])

    def test_all_windows_old_is_unknown_despite_a_fresh_top_level_stamp(self):
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T,
            "five_hour": win(10, NOW_T + 3600, NOW_T - 7300),
            "seven_day": win(10, NOW_T + 6 * 24 * 3600, NOW_T - 7300),
        })
        self.assertEqual(cbox_budget.budget_for_family("claude", now=NOW_T)["status"], "unknown")

    def test_future_window_stamp_excludes_that_window(self):
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T,
            "seven_day": win(10, NOW_T + 6 * 24 * 3600, NOW_T + 100000),
        })
        self.assertEqual(cbox_budget.budget_for_family("claude", now=NOW_T)["status"], "unknown")

    def test_files_without_window_stamps_fall_back_to_the_top_level_stamp(self):
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T - 7300,
            "seven_day": {"used_percentage": 10, "resets_at": NOW_T + 6 * 24 * 3600},
        })
        m = cbox_budget.source_metrics("claude", NOW_T)
        self.assertEqual(m["seven_day"]["captured_at"], NOW_T - 7300)
        self.assertEqual(cbox_budget.budget_for_family("claude", now=NOW_T)["status"], "unknown")

    def test_needs_refresh_is_per_window(self):
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T,
            "five_hour": win(10, NOW_T + 3600, NOW_T - 400),
            "seven_day": win(10, NOW_T + 6 * 24 * 3600, NOW_T),
        })
        self.assertTrue(cbox_budget.claude_snapshot_needs_refresh(NOW_T, 300))
        self.assertFalse(cbox_budget.claude_snapshot_needs_refresh(NOW_T, 500))

    def test_needs_refresh_for_missing_empty_or_future_snapshots(self):
        self.assertTrue(cbox_budget.claude_snapshot_needs_refresh(NOW_T, 300))
        write_source(self.usage_dir, "claude", {"captured_at": NOW_T, "five_hour": None, "seven_day": None})
        self.assertTrue(cbox_budget.claude_snapshot_needs_refresh(NOW_T, 300))
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T + 1000,
            "five_hour": win(10, NOW_T + 3600, NOW_T + 1000),
        })
        self.assertTrue(cbox_budget.claude_snapshot_needs_refresh(NOW_T, 300))

    def test_future_window_is_not_a_known_window(self):
        write_source(self.usage_dir, "claude", {
            "captured_at": NOW_T,
            "five_hour": win(10, NOW_T + 3600, NOW_T + 1000),
            "seven_day": win(20, NOW_T + 6 * 24 * 3600, NOW_T),
        })
        w = cbox_budget.read_claude_windows(NOW_T)
        self.assertIsNone(w["five_hour"])
        self.assertEqual(w["seven_day"]["used_percentage"], 20.0)


class CombineWindowTests(unittest.TestCase):
    def test_higher_usage_in_the_same_window_wins(self):
        old = win(10, 5000.0, 1.0)
        new = win(12, 5030.0, 2.0)
        self.assertIs(cbox_budget.combine_window(new, old), new)

    def test_lower_usage_in_the_same_window_never_replaces(self):
        old = win(40, 5000.0, 1.0)
        new = win(10, 5030.0, 2.0)
        self.assertIs(cbox_budget.combine_window(new, old), old)

    def test_a_real_roll_replaces_with_lower_usage(self):
        old = win(90, 5000.0, 1.0)
        new = win(2, 5000.0 + 5 * 3600, 2.0)
        self.assertIs(cbox_budget.combine_window(new, old), new)

    def test_an_older_window_never_replaces(self):
        old = win(2, 5000.0 + 5 * 3600, 1.0)
        new = win(90, 5000.0, 2.0)
        self.assertIs(cbox_budget.combine_window(new, old), old)

    def test_unknown_resets_never_replaces_a_known_resets(self):
        old = win(10, 5000.0, 1.0)
        new = win(50, None, 2.0)
        self.assertIs(cbox_budget.combine_window(new, old), old)

    def test_known_resets_replaces_an_unknown_one(self):
        old = win(10, None, 1.0)
        new = win(5, 5000.0, 2.0)
        self.assertIs(cbox_budget.combine_window(new, old), new)

    def test_missing_sides(self):
        w = win(1, 1.0, 1.0)
        self.assertIs(cbox_budget.combine_window(None, w), w)
        self.assertIs(cbox_budget.combine_window(w, None), w)
        self.assertIsNone(cbox_budget.combine_window(None, None))


class ResetsPlausibilityTests(unittest.TestCase):
    def test_bounds_per_window(self):
        self.assertTrue(cbox_budget.resets_plausible(NOW_T + 5 * 3600 + 60, NOW_T, "five_hour"))
        self.assertFalse(cbox_budget.resets_plausible(NOW_T + 5 * 3600 + 61, NOW_T, "five_hour"))
        self.assertTrue(cbox_budget.resets_plausible(NOW_T + 7 * 86400 + 60, NOW_T, "seven_day"))
        self.assertFalse(cbox_budget.resets_plausible(NOW_T + 7 * 86400 + 61, NOW_T, "seven_day"))
        self.assertTrue(cbox_budget.resets_plausible(None, NOW_T, "five_hour"))
        self.assertTrue(cbox_budget.resets_plausible(NOW_T - 10 ** 6, NOW_T, "five_hour"))

    def test_clean_window_rejects_implausible_or_unusable_entries(self):
        good = {"used_percentage": 10, "resets_at": NOW_T + 100}
        self.assertIsNotNone(cbox_budget.clean_window(good, "five_hour", NOW_T))
        far = {"used_percentage": 10, "resets_at": NOW_T + 10 ** 7}
        self.assertIsNone(cbox_budget.clean_window(far, "five_hour", NOW_T))
        self.assertIsNone(cbox_budget.clean_window({"used_percentage": None}, "five_hour", NOW_T))
        self.assertIsNone(cbox_budget.clean_window({"used_percentage": float("nan")}, "five_hour", NOW_T))
        self.assertIsNone(cbox_budget.clean_window("x", "five_hour", NOW_T))


class UpdateClaudeSnapshotTests(ClaudeSnapshotHarness):
    def test_carried_over_window_keeps_its_own_stamp_and_top_level_is_the_max(self):
        write_source(self.usage_dir, "claude", {
            "source": "claude", "captured_at": NOW_T - 500,
            "five_hour": win(10, NOW_T + 3000, NOW_T - 500),
            "seven_day": win(20, NOW_T + 400000, NOW_T - 900),
        })
        chosen, wrote = cbox_budget.update_claude_snapshot(
            {"five_hour": win(15, NOW_T + 3000, NOW_T)}, NOW_T, "claude")
        self.assertTrue(wrote)
        snap = self.snap()
        self.assertEqual(snap["captured_at"], NOW_T)
        self.assertEqual(snap["five_hour"]["captured_at"], NOW_T)
        self.assertEqual(snap["seven_day"], win(20.0, NOW_T + 400000, NOW_T - 900))

    def test_legacy_file_windows_inherit_the_top_level_stamp_when_carried(self):
        write_source(self.usage_dir, "claude", {
            "source": "claude", "captured_at": NOW_T - 500,
            "five_hour": {"used_percentage": 10, "resets_at": NOW_T + 3000},
            "seven_day": {"used_percentage": 20, "resets_at": NOW_T + 400000},
        })
        cbox_budget.update_claude_snapshot({"five_hour": win(15, NOW_T + 3000, NOW_T)}, NOW_T, "claude")
        snap = self.snap()
        self.assertEqual(snap["seven_day"]["captured_at"], NOW_T - 500)

    def test_nothing_accepted_means_no_write(self):
        write_source(self.usage_dir, "claude", {
            "source": "claude", "captured_at": NOW_T - 500,
            "five_hour": win(40, NOW_T + 3000, NOW_T - 500),
            "seven_day": None,
        })
        before = os.stat(self.snap_path()).st_mtime_ns
        chosen, wrote = cbox_budget.update_claude_snapshot(
            {"five_hour": win(10, NOW_T + 3000, NOW_T), "seven_day": None}, NOW_T, "claude")
        self.assertFalse(wrote)
        self.assertEqual(os.stat(self.snap_path()).st_mtime_ns, before)
        self.assertEqual(self.snap()["five_hour"]["used_percentage"], 40)

    def test_future_stamped_existing_window_is_not_trusted(self):
        write_source(self.usage_dir, "claude", {
            "source": "claude", "captured_at": NOW_T + 10 ** 6,
            "five_hour": win(90, NOW_T + 3000, NOW_T + 10 ** 6),
        })
        chosen, wrote = cbox_budget.update_claude_snapshot(
            {"five_hour": win(10, NOW_T + 3000, NOW_T)}, NOW_T, "claude")
        self.assertTrue(wrote)
        self.assertEqual(self.snap()["five_hour"]["used_percentage"], 10)
        self.assertEqual(self.snap()["captured_at"], NOW_T)

    def test_held_lock_skips_the_write_without_hanging(self):
        import fcntl
        import time
        fd = os.open(os.path.join(self.usage_dir, "claude.json.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            started = time.monotonic()
            chosen, wrote = cbox_budget.update_claude_snapshot(
                {"five_hour": win(10, NOW_T + 3000, NOW_T)}, NOW_T, "claude")
            elapsed = time.monotonic() - started
        finally:
            os.close(fd)
        self.assertFalse(wrote)
        self.assertLess(elapsed, 1.5)
        self.assertFalse(os.path.exists(self.snap_path()))

    def test_lock_released_after_a_write(self):
        import fcntl
        cbox_budget.update_claude_snapshot({"five_hour": win(10, NOW_T + 3000, NOW_T)}, NOW_T, "claude")
        fd = os.open(os.path.join(self.usage_dir, "claude.json.lock"), os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(fd)

    def test_fifo_lock_path_does_not_hang(self):
        import threading
        os.mkfifo(os.path.join(self.usage_dir, "claude.json.lock"))
        out = []
        t = threading.Thread(target=lambda: out.append(cbox_budget.update_claude_snapshot(
            {"five_hour": win(10, NOW_T + 3000, NOW_T)}, NOW_T, "claude")), daemon=True)
        t.start()
        t.join(3)
        self.assertFalse(t.is_alive())
        self.assertEqual(out[0][1], False)

    def test_snapshot_file_is_private(self):
        cbox_budget.update_claude_snapshot({"five_hour": win(10, NOW_T + 3000, NOW_T)}, NOW_T, "claude")
        self.assertEqual(stat.S_IMODE(os.stat(self.snap_path()).st_mode), 0o600)


class DeepNestingTests(ClaudeSnapshotHarness):
    def test_deeply_nested_json_is_unreadable_not_fatal(self):
        path = os.path.join(self.usage_dir, "claude.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write("[" * 60000)
        self.assertIsNone(cbox_budget.safe_read_json(path))
        self.assertIsNone(cbox_budget.source_metrics("claude", NOW_T))
        self.assertEqual(cbox_budget.budget_for_family("claude", now=NOW_T)["status"], "unknown")
        self.assertTrue(cbox_budget.claude_snapshot_needs_refresh(NOW_T, 300))


class SafeChmodDirTests(unittest.TestCase):
    def test_symlinked_directory_is_skipped(self):
        d = tempfile.mkdtemp()
        target = os.path.join(d, "target")
        os.mkdir(target, 0o755)
        link = os.path.join(d, "link")
        os.symlink(target, link)
        cbox_budget.safe_chmod_dir(link, 0o700)
        mode = stat.S_IMODE(os.stat(target).st_mode)
        self.assertEqual(mode, 0o755)

    def test_owned_regular_directory_is_chmodded(self):
        d = tempfile.mkdtemp()
        os.chmod(d, 0o755)
        cbox_budget.safe_chmod_dir(d, 0o700)
        mode = stat.S_IMODE(os.stat(d).st_mode)
        self.assertEqual(mode, 0o700)


class LocalTierPresenceTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.cfg = os.path.join(self._tmp.name, "cfg")
        os.makedirs(self.cfg)
        self._saved = os.environ.get("CLAUDE_CONFIG_DIR")
        os.environ["CLAUDE_CONFIG_DIR"] = self.cfg

    def tearDown(self):
        if self._saved is None:
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
        else:
            os.environ["CLAUDE_CONFIG_DIR"] = self._saved
        self._tmp.cleanup()

    def _write(self, doc):
        with open(os.path.join(self.cfg, ".claude.json"), "w", encoding="utf-8") as f:
            json.dump(doc, f)

    def test_top_level_server_is_present(self):
        self._write({"mcpServers": {"hermes-local": {}}})
        self.assertTrue(cbox_budget.local_tier_present("/nowhere"))

    def test_other_servers_do_not_count(self):
        self._write({"mcpServers": {"codex-sol": {}}, "projects": {"/p": {"mcpServers": {"local-qwen": {}}}}})
        self.assertFalse(cbox_budget.local_tier_present("/p"))

    def test_project_scope_matches_the_exact_key_only(self):
        self._write({"projects": {"/p": {"mcpServers": {"hermes-local": {}}}}})
        self.assertTrue(cbox_budget.local_tier_present("/p"))
        self.assertFalse(cbox_budget.local_tier_present("/p/a/b"))
        self.assertFalse(cbox_budget.local_tier_present("/q"))
        self.assertFalse(cbox_budget.local_tier_present("/pp"))

    def test_disabled_list_removes_the_server_for_the_exact_key_only(self):
        self._write({"mcpServers": {"hermes-local": {}},
                     "projects": {"/p": {"disabledMcpServers": ["hermes-local"]}}})
        self.assertFalse(cbox_budget.local_tier_present("/p"))
        self.assertTrue(cbox_budget.local_tier_present("/p/x"))
        self.assertTrue(cbox_budget.local_tier_present("/other"))

    def test_realpath_variant_of_the_cwd_matches(self):
        real = os.path.join(self._tmp.name, "realdir")
        link = os.path.join(self._tmp.name, "linkdir")
        os.makedirs(real)
        os.symlink(real, link)
        self._write({"projects": {os.path.realpath(real): {"mcpServers": {"hermes-local": {}}}}})
        self.assertTrue(cbox_budget.local_tier_present(link))

    def test_missing_config_is_absent_and_well_formed_without_the_server_is_absent(self):
        self.assertFalse(cbox_budget.local_tier_present("/p"))
        self._write({"mcpServers": ["hermes-local"], "projects": {"/p": "x"}})
        self.assertFalse(cbox_budget.local_tier_present("/p"))
        self._write({})
        self.assertFalse(cbox_budget.local_tier_present("/p"))

    def test_unreadable_or_odd_configs_are_present(self):
        path = os.path.join(self.cfg, ".claude.json")
        cases = {
            "invalid": b"{oops",
            "partial": b'{"mcpServers": {"x": ',
            "non-object": b"[1, 2]",
            "deep": b"[" * 100000,
            "not-utf8": b"\xff\xfe{}",
        }
        for name, raw in cases.items():
            with self.subTest(case=name):
                with open(path, "wb") as f:
                    f.write(raw)
                self.assertTrue(cbox_budget.local_tier_present("/p"))

    def test_oversize_config_is_present(self):
        path = os.path.join(self.cfg, ".claude.json")
        with open(path, "wb") as f:
            f.write(b'{"h": "' + b"x" * cbox_budget.CLAUDE_JSON_READ_CAP_BYTES + b'"}')
        self.assertTrue(cbox_budget.local_tier_present("/p"))

    def test_non_regular_config_is_present(self):
        os.mkdir(os.path.join(self.cfg, ".claude.json"))
        self.assertTrue(cbox_budget.local_tier_present("/p"))

    def test_symlinked_config_is_present(self):
        real = os.path.join(self._tmp.name, "real.json")
        with open(real, "w", encoding="utf-8") as f:
            json.dump({"mcpServers": {"codex-sol": {}}}, f)
        os.symlink(real, os.path.join(self.cfg, ".claude.json"))
        self.assertTrue(cbox_budget.local_tier_present("/p"))

    def test_unreadable_directory_component_is_present(self):
        blocker = os.path.join(self._tmp.name, "blocker")
        with open(blocker, "w", encoding="utf-8") as f:
            f.write("x")
        os.environ["CLAUDE_CONFIG_DIR"] = blocker
        self.assertTrue(cbox_budget.local_tier_present("/p"))

    def test_deleted_working_directory_without_a_cwd_is_present(self):
        self._write({"projects": {"/p": {"mcpServers": {}}}})
        gone = os.path.join(self._tmp.name, "gone")
        os.makedirs(gone)
        saved = os.getcwd()
        os.chdir(gone)
        os.rmdir(gone)
        try:
            self.assertTrue(cbox_budget.local_tier_present())
            self.assertFalse(cbox_budget.local_tier_present("/p/sub"))
        finally:
            os.chdir(saved)

    def test_unset_config_dir_falls_back_to_home(self):
        home = os.path.join(self._tmp.name, "home")
        os.makedirs(home)
        with open(os.path.join(home, ".claude.json"), "w", encoding="utf-8") as f:
            json.dump({"mcpServers": {"hermes-local": {}}}, f)
        del os.environ["CLAUDE_CONFIG_DIR"]
        saved_home = os.environ.get("HOME")
        os.environ["HOME"] = home
        try:
            self.assertTrue(cbox_budget.local_tier_present("/p"))
        finally:
            if saved_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = saved_home


if __name__ == "__main__":
    unittest.main()
