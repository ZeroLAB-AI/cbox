import importlib.util
import json
import os
import pathlib
import stat
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOOKS = ROOT / "etc" / "hooks"
spec = importlib.util.spec_from_file_location("limit_watchdog", str(HOOKS / "limit_watchdog.py"))
import sys
sys.path.insert(0, str(HOOKS))
wd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wd)


class RegulatorTests(unittest.TestCase):
    def test_hard_limit_defaults(self):
        self.assertEqual(wd.DELAY, 10)
        self.assertEqual(wd.STAGGER, 3)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = os.path.join(self.tmp.name, ".claude-cbox")
        self.sid = "s-123"
        self.transcript = os.path.join(self.cfg, "projects", "project", self.sid + ".jsonl")
        os.makedirs(os.path.dirname(self.transcript))
        with open(self.transcript, "wb") as fh:
            fh.write(b'{"type":"user","message":{"content":"first"}}\n')
        self.old = (wd.CFG, wd.WATCH, wd.MARKERS, wd.PANES, wd.REGULATOR_AUTORESUME)
        wd.CFG = self.cfg
        wd.WATCH = os.path.join(self.cfg, "limit-watch")
        wd.MARKERS = os.path.join(wd.WATCH, "markers")
        wd.PANES = os.path.join(wd.WATCH, "panes")
        wd.REGULATOR_AUTORESUME = True
        wd._LOG_SEEN.clear()
        self.path = wd.marker_path(self.sid, None, "regulator")
        self.now = 1700000000

    def tearDown(self):
        wd.CFG, wd.WATCH, wd.MARKERS, wd.PANES, wd.REGULATOR_AUTORESUME = self.old
        wd._LOG_SEEN.clear()
        self.tmp.cleanup()

    def _append(self, entry):
        with open(self.transcript, "ab") as fh:
            fh.write((json.dumps(entry) + "\n").encode("ascii"))

    def _marker(self, due=None):
        self.assertTrue(wd.write_regulator_marker(
            self.sid, self.transcript, self.now if due is None else due, self.now - 1))
        with open(self.path) as fh:
            return json.load(fh)

    def _pass(self, budget):
        with patch.object(wd.time, "time", return_value=self.now), \
             patch.object(wd.cbox_budget, "budget_for_family", return_value=budget), \
             patch.object(wd, "pane_for", return_value={"container": wd.HOSTNAME, "pane": "%1"}), \
             patch.object(wd, "pane_alive", return_value=True), \
             patch.object(wd, "pane_idle", return_value=True), \
             patch.object(wd, "inject", return_value=None) as injected:
            wd.regulator_pass()
            return injected

    def test_marker_overwrites_per_session_and_refuses_invalid_id_and_symlink(self):
        first = self._marker()
        self.assertEqual(first["kind"], "regulator")
        self.assertEqual(first["transcript_offset"], os.path.getsize(self.transcript))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        self._marker(self.now + 5)
        self.assertEqual(len(os.listdir(wd.MARKERS)), 1)
        self.assertEqual(wd.load_json(self.path)["due"], self.now + 5)
        self.assertFalse(wd.write_regulator_marker("../bad", self.transcript, self.now))
        os.unlink(self.path)
        target = os.path.join(self.tmp.name, "target")
        with open(target, "w") as fh:
            fh.write("safe")
        os.symlink(target, self.path)
        self.assertFalse(wd.write_regulator_marker(self.sid, self.transcript, self.now))
        with open(target) as fh:
            self.assertEqual(fh.read(), "safe")

    def test_tool_result_and_assistant_close_do_not_cancel(self):
        marker = self._marker()
        self._append({"type": "user", "message": {"content": [{"type": "tool_result", "content": "done"}]}})
        self._append({"type": "user", "isMeta": True, "message": {"content": "meta"}})
        self._append({"type": "user", "source": "synthetic", "message": {"content": "synthetic"}})
        self._append({"type": "assistant", "message": {"content": "done", "stop_reason": "end_turn"}})
        self.assertFalse(wd.human_prompt_after_event(marker))
        injected = self._pass({"status": "ok", "b": 2.0, "n": 3})
        injected.assert_called_once_with("%1", "cbox: quota reset at 22:13:18Z, agents: 3; continue the blocked step")
        self.assertFalse(os.path.exists(self.path))

    def test_human_prompt_after_offset_cancels(self):
        self._marker()
        self._append({"type": "user", "message": {"content": "continue"}})
        injected = self._pass({"status": "ok", "b": 2.0, "n": 3})
        injected.assert_not_called()
        self.assertFalse(os.path.exists(self.path))

    def test_image_prompt_cancels_but_tool_result_does_not(self):
        marker = self._marker()
        self._append({"type": "user", "message": {"content": [{"type": "tool_result", "content": "done"}]}})
        self.assertFalse(wd.human_prompt_after_event(marker))
        self._append({"type": "user", "message": {"content": [{"type": "text", "text": "look"}, {"type": "image", "source": "picture"}]}})
        self.assertTrue(wd.human_prompt_after_event(marker))
        self._pass({"status": "ok", "b": 2.0, "n": 3}).assert_not_called()
        self.assertFalse(os.path.exists(self.path))

    def test_transcript_idle_check_requires_end_turn(self):
        marker = self._marker()
        self._append({"type": "assistant", "message": {"stop_reason": "tool_use"}})
        self.assertFalse(wd.pane_idle(marker))
        self._append({"type": "assistant", "message": {"stop_reason": "end_turn"}})
        self.assertTrue(wd.pane_idle(marker))
        self._append({"type": "user", "message": {"content": "new question"}})
        self.assertFalse(wd.pane_idle(marker))

    def test_prompt_arriving_during_pane_lookup_prevents_injection(self):
        self._marker()
        def pane_for(_sid):
            self._append({"type": "user", "message": {"content": "new question"}})
            return {"container": wd.HOSTNAME, "pane": "%1"}
        with patch.object(wd.time, "time", return_value=self.now), \
             patch.object(wd.cbox_budget, "budget_for_family", return_value={"status": "ok", "b": 2.0, "n": 3}), \
             patch.object(wd, "pane_for", side_effect=pane_for), \
             patch.object(wd, "pane_alive", return_value=True), \
             patch.object(wd, "inject") as injected:
            wd.regulator_pass()
            injected.assert_not_called()

    def test_deny_rearms_to_next_binding_reset(self):
        self._marker()
        next_reset = self.now + 3600
        injected = self._pass({"status": "ok", "b": 0.2, "n": 0, "resets_at": next_reset})
        injected.assert_not_called()
        self.assertEqual(wd.load_json(self.path)["due"], next_reset + 2)

    def test_busy_pane_retries_and_off_switch_keeps_marker(self):
        self._marker()
        wd.REGULATOR_AUTORESUME = False
        self._pass({"status": "ok", "b": 2.0, "n": 3})
        self.assertTrue(os.path.exists(self.path))
        self.assertEqual(wd.next_sleep(self.now), 15)
        wd.REGULATOR_AUTORESUME = True
        with patch.object(wd.time, "time", return_value=self.now), \
             patch.object(wd.cbox_budget, "budget_for_family", return_value={"status": "ok", "b": 2.0, "n": 3}), \
             patch.object(wd, "pane_for", return_value={"container": wd.HOSTNAME, "pane": "%1"}), \
             patch.object(wd, "pane_alive", return_value=True), \
             patch.object(wd, "pane_idle", return_value=False), \
             patch.object(wd, "inject") as injected:
            wd.regulator_pass()
            injected.assert_not_called()
        self.assertTrue(os.path.exists(self.path))

    def test_off_spellings(self):
        for value in ("off", "0", "false", "no", ""):
            self.assertFalse(wd.regulator_autoresume_enabled(value))
        self.assertTrue(wd.regulator_autoresume_enabled("on"))

    def test_six_hour_expiry_and_separate_daily_count(self):
        marker = self._marker(self.now + 7 * 3600)
        marker["first_due"] = self.now - wd.REGULATOR_EXPIRY
        with open(self.path, "w") as fh:
            json.dump(marker, fh)
        self.assertEqual(wd.next_sleep(self.now), 15)
        injected = self._pass({"status": "ok", "b": 2.0, "n": 3})
        injected.assert_not_called()
        self.assertFalse(os.path.exists(self.path))
        self._marker()
        for _ in range(wd.MAX_PER_DAY):
            wd._regulator_record_count(self.sid, self.now)
        injected = self._pass({"status": "ok", "b": 2.0, "n": 3})
        injected.assert_not_called()
        self.assertFalse(os.path.exists(self.path))

    def test_sleep_bounds(self):
        self.assertEqual(wd.next_sleep(self.now), 15)
        self._marker(self.now + 2)
        self.assertEqual(wd.next_sleep(self.now), 2)
        self.assertEqual(wd.next_sleep(self.now + 5), 15)
        self.assertEqual(wd.next_sleep(self.now - 100), 15)

    def test_log_dedupe_and_rotation(self):
        wd.log("reconciled stale job: id=one prevState=running")
        wd.log("reconciled stale job: id=one prevState=running")
        path = os.path.join(wd.WATCH, "watchdog.log")
        with open(path) as fh:
            self.assertEqual(len(fh.readlines()), 1)
        with open(path, "w") as fh:
            fh.write("x" * wd.LOG_LIMIT)
        wd.log("next transition")
        self.assertTrue(os.path.isfile(path + ".1"))
        self.assertLess(os.path.getsize(path), 100)
        with open(path, "w") as fh:
            fh.write("x" * wd.LOG_LIMIT)
        wd.log("another transition")
        self.assertEqual(len([n for n in os.listdir(wd.WATCH) if n.startswith("watchdog.log.") and n != "watchdog.log.lock"]), 1)

    def test_log_dedupe_keeps_one_state_per_job_and_refuses_symlink(self):
        first = "reconciled stale job: id=one prevState=running"
        second = "reconciled stale job: id=one prevState=blocked"
        wd.log(first)
        wd.log(first)
        wd.log(second)
        wd.log(first)
        self.assertEqual(len(wd._LOG_SEEN), 1)
        path = os.path.join(wd.WATCH, "watchdog.log")
        with open(path) as fh:
            self.assertEqual(len(fh.readlines()), 3)
        os.unlink(path)
        target = os.path.join(self.tmp.name, "target")
        with open(target, "w") as fh:
            fh.write("safe")
        os.symlink(target, path)
        wd.log("next transition")
        with open(target) as fh:
            self.assertEqual(fh.read(), "safe")

    def test_invalid_marker_does_not_block_other_session(self):
        self._marker()
        marker = wd.load_json(self.path)
        marker["due"] = -1e300
        with open(self.path, "w") as fh:
            json.dump(marker, fh)
        second = "s-456"
        second_path = os.path.join(os.path.dirname(self.transcript), second + ".jsonl")
        with open(second_path, "wb") as fh:
            fh.write(b'{"type":"assistant","message":{"stop_reason":"end_turn"}}\n')
        self.assertTrue(wd.write_regulator_marker(second, second_path, self.now, self.now - 1))
        injected = self._pass({"status": "ok", "b": 2.0, "n": 3})
        injected.assert_called_once()
        self.assertFalse(os.path.exists(self.path))

    def test_rearm_and_inject_preserve_newer_marker(self):
        self._marker()
        newer_due = self.now + 1800
        def new_budget(_family, now):
            self.assertTrue(wd.write_regulator_marker(self.sid, self.transcript, newer_due, self.now))
            return {"status": "ok", "b": 0.2, "n": 0, "resets_at": self.now + 3600}
        with patch.object(wd.time, "time", return_value=self.now), \
             patch.object(wd.cbox_budget, "budget_for_family", side_effect=new_budget):
            wd.regulator_pass()
        self.assertEqual(wd.load_json(self.path)["due"], newer_due)
        self._marker()
        def inject_new(_pane, _prompt):
            self.assertTrue(wd.write_regulator_marker(self.sid, self.transcript, newer_due, self.now))
        with patch.object(wd.time, "time", return_value=self.now), \
             patch.object(wd.cbox_budget, "budget_for_family", return_value={"status": "ok", "b": 2.0, "n": 3}), \
             patch.object(wd, "pane_for", return_value={"container": wd.HOSTNAME, "pane": "%1"}), \
             patch.object(wd, "pane_alive", return_value=True), \
             patch.object(wd, "pane_idle", return_value=True), \
             patch.object(wd, "inject", side_effect=inject_new):
            wd.regulator_pass()
        self.assertEqual(wd.load_json(self.path)["due"], newer_due)

    def test_transcript_path_and_read_are_bounded(self):
        marker = self._marker()
        outside = os.path.join(self.tmp.name, "outside")
        os.makedirs(outside)
        outside_path = os.path.join(outside, self.sid + ".jsonl")
        with open(outside_path, "wb") as fh:
            fh.write(b"{}\n")
        traversal = os.path.join(self.cfg, "projects", "..", "..", "outside", self.sid + ".jsonl")
        self.assertFalse(wd.marker_owns_transcript({"transcript_path": traversal}, self.sid))
        os.unlink(self.transcript)
        os.symlink(outside_path, self.transcript)
        self.assertTrue(wd.human_prompt_after_event(marker))
        os.unlink(self.transcript)
        os.mkfifo(self.transcript)
        self.assertTrue(wd.human_prompt_after_event(marker))
        os.unlink(self.transcript)
        with open(self.transcript, "wb") as fh:
            fh.write(b"x" * (4 * 1024 * 1024 + 1))
        marker["transcript_offset"] = 0
        self.assertTrue(wd.human_prompt_after_event(marker))

    def test_prune_removes_stale_counts_and_temp_files(self):
        self._marker()
        count_dir = os.path.join(wd.WATCH, "regulator-counts")
        os.makedirs(count_dir)
        count = os.path.join(count_dir, self.sid + ".json")
        with open(count, "w") as fh:
            json.dump({"times": [self.now - 25 * 3600]}, fh)
        temp_paths = [os.path.join(wd.MARKERS, ".regulator.orphan"),
                      os.path.join(count_dir, ".count.orphan")]
        for path in temp_paths:
            with open(path, "w") as fh:
                fh.write("orphan")
            os.utime(path, (self.now - 4000, self.now - 4000))
        with patch.object(wd.time, "time", return_value=self.now):
            wd.prune()
        self.assertFalse(os.path.exists(count))
        self.assertTrue(all(not os.path.exists(path) for path in temp_paths))


if __name__ == "__main__":
    unittest.main()
