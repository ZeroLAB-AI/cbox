#!/usr/bin/env python3
import fcntl
import os
import tempfile

LIVE_STATE_DIR = "/tmp/cbox-paid-agents"
LIVE_STATE_BEFORE = sorted(os.listdir(LIVE_STATE_DIR)) if os.path.exists(LIVE_STATE_DIR) else None
TEST_STATE = tempfile.TemporaryDirectory()

for _k in [k for k in os.environ if k.startswith("CBOX_")]:
    os.environ.pop(_k)
os.environ["CBOX_PAID_AGENT_DIR"] = os.path.join(TEST_STATE.name, "state")

import json
import importlib.util
import pathlib
import subprocess
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
TRACKER = ROOT / "etc" / "hooks" / "paid_agent_tracker.py"


def tearDownModule():
    after = sorted(os.listdir(LIVE_STATE_DIR)) if os.path.exists(LIVE_STATE_DIR) else None
    TEST_STATE.cleanup()
    if after != LIVE_STATE_BEFORE:
        raise AssertionError("live paid-agent state changed during tests")


def run(stdin, state_dir, profile="low", args=(), extra=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith("CBOX_")}
    e["CBOX_PAID_AGENT_DIR"] = state_dir
    if profile is None:
        pass
    else:
        e["CBOX_SUBSCRIPTION_PROFILE"] = profile
    if extra:
        e.update(extra)
    return subprocess.run(
        ["python3", str(TRACKER)] + list(args),
        input=stdin, capture_output=True, text=True, timeout=30, env=e)


def start(agent_id="a1", agent_type="worker"):
    return json.dumps({"hook_event_name": "SubagentStart", "session_id": "s1",
                       "agent_id": agent_id, "agent_type": agent_type})


def stop(agent_id="a1", agent_type="worker"):
    return json.dumps({"hook_event_name": "SubagentStop", "session_id": "s1",
                       "agent_id": agent_id, "agent_type": agent_type,
                       "stop_hook_active": False})


def tracker_module():
    spec = importlib.util.spec_from_file_location("pat_probe_%d" % time.time_ns(), str(TRACKER))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TrackerTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp()
        self.dir = os.path.abspath(os.path.join(self.base, "state"))

    def markers(self):
        return sorted(name for name in os.listdir(self.dir) if name != ".lock") if os.path.isdir(self.dir) else []

    def test_low_start_writes_marker(self):
        proc = run(start(), self.dir)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "")
        self.assertEqual(self.markers(), ["a1"])
        with open(os.path.join(self.dir, "a1")) as fh:
            rec = json.load(fh)
        self.assertNotIn("agent_id", rec)
        self.assertEqual(rec["agent_type"], "worker")
        self.assertEqual(rec["session_id"], "s1")
        self.assertEqual(rec["main_transcript_dir"], "")
        self.assertIn("ts", rec)
        self.assertEqual(os.stat(self.dir).st_mode & 0o777, 0o700)

    def test_high_start_is_noop(self):
        for profile in ("high", "max", None, "bogus"):
            proc = run(start(), self.dir, profile=profile)
            self.assertEqual(proc.returncode, 0)
        self.assertEqual(self.markers(), [])

    def test_profile_is_normalized(self):
        run(start(), self.dir, profile="  LOW ")
        self.assertEqual(self.markers(), ["a1"])

    def test_free_agent_types_are_not_tracked(self):
        run(start("h1", "hermes-local"), self.dir)
        run(start("h2", "aevum-elm"), self.dir)
        self.assertEqual(self.markers(), [])

    def test_stop_removes_marker_regardless_of_profile(self):
        run(start(), self.dir)
        self.assertEqual(self.markers(), ["a1"])
        proc = run(stop(), self.dir, profile="high")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(self.markers(), [])

    def test_large_stop_payload_removes_marker(self):
        for size in (70000, 20 * 1024 * 1024):
            run(start(), self.dir)
            payload = json.loads(stop())
            payload["last_assistant_message"] = "x" * size
            proc = run(json.dumps(payload), self.dir)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(proc.stdout, "")
            self.assertEqual(self.markers(), [])

    def test_agent_id_is_sanitized(self):
        run(start("../x/y z"), self.dir)
        self.assertEqual(self.markers(), ["xyz"])
        run(start("a" * 300), self.dir)
        self.assertIn("a" * 128, self.markers())

    def test_empty_agent_id_is_skipped(self):
        run(start("///"), self.dir)
        self.assertEqual(self.markers(), [])

    def test_symlinked_state_dir_is_not_written(self):
        target = os.path.join(self.base, "target")
        os.makedirs(target)
        os.symlink(target, self.dir)
        proc = run(start(), self.dir)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(os.listdir(target), [])

    def test_garbage_stdin_exits_zero_silently(self):
        for blob in ("", "not json", "[1,2]", "null", '{"hook_event_name": 5}'):
            proc = run(blob, self.dir)
            self.assertEqual(proc.returncode, 0, blob)
            self.assertEqual(proc.stdout, "", blob)
        self.assertEqual(self.markers(), [])

    def test_clear_requires_stale_or_explicit_target_and_never_follows_symlinks(self):
        run(start("a1"), self.dir)
        run(start("a2"), self.dir)
        outside = os.path.join(self.base, "outside")
        with open(outside, "w") as fh:
            fh.write("keep")
        os.symlink(outside, os.path.join(self.dir, "link"))
        proc = run("", self.dir, args=["clear"])
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "0")
        self.assertEqual(self.markers(), ["a1", "a2", "link"])
        self.assertEqual(run("", self.dir, args=["clear", "a1"]).stdout.strip(), "1")
        self.assertEqual(self.markers(), ["a2", "link"])
        self.assertEqual(run("", self.dir, args=["clear", "--all"]).stdout.strip(), "1")
        self.assertEqual(self.markers(), ["link"])
        self.assertTrue(os.path.exists(outside))

    def test_taskstop_and_session_events(self):
        run(start(), self.dir)
        event = {"hook_event_name": "PostToolUse", "tool_name": "TaskStop",
                 "tool_input": {"task_id": "a1"}}
        self.assertEqual(run(json.dumps(event), self.dir).stdout, "")
        self.assertEqual(self.markers(), [])
        run(start(), self.dir)
        compact = {"hook_event_name": "SessionStart", "source": "compact", "session_id": "s1"}
        run(json.dumps(compact), self.dir)
        self.assertEqual(self.markers(), ["a1"])
        compact["source"] = "resume"
        run(json.dumps(compact), self.dir)
        self.assertEqual(self.markers(), [])
        run(start(), self.dir)
        run(json.dumps({"hook_event_name": "SessionEnd", "session_id": "s1"}), self.dir)
        self.assertEqual(self.markers(), [])

    def test_session_cleanup_removes_pending_for_its_session_only(self):
        os.environ["CBOX_PAID_AGENT_DIR"] = self.dir
        os.environ["CBOX_SUBSCRIPTION_PROFILE"] = "low"
        try:
            mod = tracker_module()
            self.assertEqual(mod.reserve_paid_agent("worker", "s1", "use1"), [])
            with open(os.path.join(self.dir, "pending-use2"), "w", encoding="ascii") as fh:
                json.dump({"kind": "pending", "agent_type": "worker", "session_id": "s2",
                           "ts": time.time()}, fh)
            run(json.dumps({"hook_event_name": "SessionStart", "source": "resume",
                            "session_id": "s1"}), self.dir)
            self.assertEqual(self.markers(), ["pending-use2"])
        finally:
            os.environ.pop("CBOX_PAID_AGENT_DIR", None)
            os.environ.pop("CBOX_SUBSCRIPTION_PROFILE", None)

    def test_clear_removes_expired_pending_but_keeps_live_marker(self):
        run(start("a2"), self.dir)
        os.environ["CBOX_PAID_AGENT_DIR"] = self.dir
        os.environ["CBOX_SUBSCRIPTION_PROFILE"] = "low"
        try:
            path = os.path.join(self.dir, "pending-use1")
            with open(path, "w", encoding="ascii") as fh:
                json.dump({"kind": "pending", "agent_type": "worker", "session_id": "s1",
                           "ts": time.time() - 60}, fh)
            proc = run("", self.dir, args=["clear"])
            self.assertEqual(proc.stdout.strip(), "1")
            self.assertEqual(self.markers(), ["a2"])
        finally:
            os.environ.pop("CBOX_PAID_AGENT_DIR", None)
            os.environ.pop("CBOX_SUBSCRIPTION_PROFILE", None)

    def test_old_temp_file_does_not_block_start_and_clear_removes_it(self):
        os.makedirs(self.dir, exist_ok=True)
        old_name = ".tmp-a1-4242"
        old_path = os.path.join(self.dir, old_name)
        pathlib.Path(old_path).write_text("incomplete", encoding="ascii")
        old = time.time() - 61
        os.utime(old_path, (old, old))
        os.environ["CBOX_PAID_AGENT_DIR"] = self.dir
        os.environ["CBOX_SUBSCRIPTION_PROFILE"] = "low"
        try:
            with mock.patch("os.getpid", return_value=4242):
                tracker_module().on_start(json.loads(start()))
        finally:
            os.environ.pop("CBOX_PAID_AGENT_DIR", None)
            os.environ.pop("CBOX_SUBSCRIPTION_PROFILE", None)
        self.assertIn("a1", self.markers())
        fresh_path = os.path.join(self.dir, ".tmp-fresh")
        pathlib.Path(fresh_path).write_text("incomplete", encoding="ascii")
        outside = os.path.join(self.base, "outside")
        pathlib.Path(outside).write_text("keep", encoding="ascii")
        link_path = os.path.join(self.dir, ".tmp-link")
        os.symlink(outside, link_path)
        proc = run("", self.dir, args=["clear"])
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "1")
        self.assertFalse(os.path.exists(old_path))
        self.assertTrue(os.path.exists(fresh_path))
        self.assertTrue(os.path.islink(link_path))
        self.assertTrue(os.path.exists(os.path.join(self.dir, "a1")))
        proc = run("", self.dir, args=["clear", "--all"])
        self.assertEqual(proc.stdout.strip(), "2")
        self.assertFalse(os.path.exists(fresh_path))
        self.assertTrue(os.path.islink(link_path))
        self.assertTrue(os.path.exists(outside))


class RunningTests(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.abspath(os.path.join(tempfile.mkdtemp(), "state"))
        for _k in [k for k in os.environ if k.startswith("CBOX_")]:
            os.environ.pop(_k)
        os.environ["CBOX_PAID_AGENT_DIR"] = self.dir
        self.mod = tracker_module()

    def tearDown(self):
        for _k in [k for k in os.environ if k.startswith("CBOX_")]:
            os.environ.pop(_k)

    def markers(self):
        return sorted(name for name in os.listdir(self.dir) if name != ".lock") if os.path.isdir(self.dir) else []

    def put(self, name, ts, raw=None):
        os.makedirs(self.dir, exist_ok=True)
        with open(os.path.join(self.dir, name), "w") as fh:
            fh.write(raw if raw is not None else json.dumps(
                {"agent_id": name, "agent_type": "worker", "session_id": "s", "ts": ts}))

    def test_live_marker_listed(self):
        self.put("a1", time.time())
        self.assertEqual([r["agent_id"] for r in self.mod.running_paid_agents()], ["a1"])

    def test_stale_marker_is_ignored_and_deleted(self):
        self.put("old", time.time() - 13 * 3600)
        self.assertEqual(self.mod.running_paid_agents(), [])
        self.assertFalse(os.path.exists(os.path.join(self.dir, "old")))

    def test_four_hour_old_marker_remains_live(self):
        self.put("a1", time.time() - 4 * 3600)
        self.assertEqual([r["agent_id"] for r in self.mod.running_paid_agents()], ["a1"])

    def test_ttl_env_override(self):
        os.environ["CBOX_PAID_AGENT_TTL_H"] = "0.001"
        self.put("a1", time.time() - 60)
        self.assertEqual(self.mod.running_paid_agents(), [])

    def test_bad_ttl_falls_back_to_default(self):
        for bad in ("nan", "inf", "-1", "0", "x"):
            os.environ["CBOX_PAID_AGENT_TTL_H"] = bad
            self.assertEqual(self.mod.ttl_seconds(), 12.0 * 3600)

    def test_unparsable_and_symlinked_markers_skipped(self):
        self.put("bad", 0, raw="not json")
        outside = os.path.join(os.path.dirname(self.dir), "outside")
        with open(outside, "w") as fh:
            fh.write(json.dumps({"agent_id": "x", "agent_type": "worker", "ts": time.time()}))
        os.symlink(outside, os.path.join(self.dir, "link"))
        self.assertEqual(self.mod.running_paid_agents(), [])

    def test_missing_dir_is_empty(self):
        self.assertEqual(self.mod.running_paid_agents(), [])

    def test_reservation_is_idempotent_and_expires(self):
        os.environ["CBOX_SUBSCRIPTION_PROFILE"] = "low"
        try:
            self.assertEqual(self.mod.reserve_paid_agent("worker", "s", "use1"), [])
            self.assertEqual(self.mod.reserve_paid_agent("worker", "s", "use1"), [])
            self.assertEqual(self.mod.running_paid_agents()[0]["kind"], "pending")
            self.assertEqual(len(self.mod.reserve_paid_agent("worker", "s", "use2")), 1)
            os.environ["CBOX_PAID_AGENT_PENDING_TTL_S"] = "1"
            path = os.path.join(self.dir, "pending-use1")
            with open(path, encoding="ascii") as fh:
                rec = json.load(fh)
            rec["ts"] = time.time() - 2
            with open(path, "w", encoding="ascii") as fh:
                json.dump(rec, fh)
            self.assertEqual(self.mod.reserve_paid_agent("worker", "s", "use2"), [])
        finally:
            os.environ.pop("CBOX_SUBSCRIPTION_PROFILE", None)

    def test_start_converts_pending_and_idle_transcript_is_removed(self):
        os.environ["CBOX_SUBSCRIPTION_PROFILE"] = "low"
        try:
            self.mod.reserve_paid_agent("worker", "s1", "use1")
            transcript = os.path.join(os.path.dirname(self.dir), "s1.jsonl")
            payload = json.loads(start())
            payload["transcript_path"] = transcript
            self.mod.on_start(payload)
            self.assertEqual([r["agent_id"] for r in self.mod.running_paid_agents()], ["a1"])
            path = os.path.join(os.path.dirname(self.dir), "s1", "subagents", "agent-a1.jsonl")
            self.assertEqual(self.mod.running_paid_agents()[0]["main_transcript_dir"],
                             os.path.dirname(self.dir))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            pathlib.Path(path).write_text("done", encoding="ascii")
            old = time.time() - 21 * 60
            os.utime(path, (old, old))
            self.assertEqual(self.mod.running_paid_agents(), [])
            self.assertFalse(os.path.exists(os.path.join(self.dir, "a1")))
        finally:
            os.environ.pop("CBOX_SUBSCRIPTION_PROFILE", None)

    def put_raw(self, name, raw, ts=None):
        os.makedirs(self.dir, exist_ok=True)
        with open(os.path.join(self.dir, name), "w") as fh:
            fh.write(raw if raw is not None else json.dumps(
                {"agent_id": name, "agent_type": "worker", "session_id": "s",
                 "ts": time.time() if ts is None else ts}))

    def test_crafted_marker_fields_never_leak_into_the_record(self):
        self.put_raw("evil", json.dumps({
            "agent_id": "x`rm -rf ~`", "agent_type": "worker); $(reboot)",
            "ts": time.time(), "session_id": "s; rm -rf /"}))
        live = self.mod.running_paid_agents()
        self.assertEqual([r["agent_id"] for r in live], ["evil"])
        self.assertEqual(live[0]["agent_type"], "workerreboot")
        combined = json.dumps(live)
        self.assertNotIn("`", combined)
        self.assertNotIn("(", combined)
        self.assertNotIn("$", combined)

    def test_pending_record_id_comes_from_the_file_name(self):
        self.put_raw("pending-bogus", json.dumps({
            "kind": "marker", "agent_id": "forged", "agent_type": "worker",
            "ts": time.time()}))
        live = self.mod.running_paid_agents()
        self.assertEqual(live[0]["kind"], "pending")
        self.assertEqual(live[0]["agent_id"], "bogus")

    def probe_guard(self):
        spec = importlib.util.spec_from_file_location("alg_probe_%d" % time.time_ns(),
                                                     str(ROOT / "etc" / "hooks" / "agent_label_guard.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def guard_probe_env(self):
        old = {k: v for k, v in os.environ.items()
               if k.startswith("CBOX_") and k != "CBOX_PAID_AGENT_DIR"}
        for k in old:
            os.environ.pop(k)
        os.environ["CBOX_SUBSCRIPTION_PROFILE"] = "low"
        return old

    def restore_guard_env(self, old):
        for k in old:
            os.environ.pop(k, None)
        os.environ.update(old)
        os.environ.pop("CBOX_SUBSCRIPTION_PROFILE", None)

    def test_crafted_marker_content_never_reaches_the_guard_message(self):
        self.put_raw("evil", json.dumps({
            "agent_id": "x`rm -rf ~`", "agent_type": "worker); $(reboot)",
            "ts": time.time(), "session_id": "s; rm -rf /"}))
        guard = self.probe_guard()
        old = self.guard_probe_env()
        try:
            live = self.mod.running_paid_agents()
            self.assertEqual(guard.paid_running_deny_reason(None),
                             ("CBOX_SUBSCRIPTION_PROFILE=low allows one paid agent at a time; "
                              "running: running workerreboot evil 0m; wait for completion, or send "
                              "this step to hermes-local; if this marker is known dead, run "
                              "python3 ~/.claude/hooks/paid_agent_tracker.py clear evil"))
            self.assertEqual(guard.paid_running_deny_reason(live),
                             guard.paid_running_deny_reason(None))
        finally:
            self.restore_guard_env(old)

    def test_huge_and_future_timestamps_are_treated_as_stale_and_deleted(self):
        for label, ts in (("huge", 10 ** 400), ("future", time.time() + 3600)):
            with self.subTest(ts=label):
                self.put("bad-ts", ts)
                self.assertEqual(self.mod.running_paid_agents(), [])
                self.assertFalse(os.path.exists(os.path.join(self.dir, "bad-ts")))

    def test_slightly_future_timestamp_within_grace_is_live(self):
        self.put("a1", time.time() + 30)
        self.assertEqual([r["agent_id"] for r in self.mod.running_paid_agents()], ["a1"])

    def test_lock_file_is_a_directory_refuses_and_reset_repairs(self):
        os.makedirs(self.dir, exist_ok=True)
        os.mkdir(os.path.join(self.dir, ".lock"))
        guard = self.probe_guard()
        old = self.guard_probe_env()
        try:
            reason = guard.reserve_paid_deny_reason("worker", {"session_id": "s", "tool_use_id": "u1"})
            self.assertIsNotNone(reason)
            self.assertIn("reset", reason)
            proc = run("", self.dir, args=["reset"])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("removed .lock", proc.stdout)
            self.assertTrue(os.path.isdir(self.dir))
            self.assertEqual(os.stat(self.dir).st_mode & 0o777, 0o700)
            self.assertTrue(os.path.isfile(os.path.join(self.dir, ".lock")))
            self.assertIsNone(guard.reserve_paid_deny_reason("worker",
                                                             {"session_id": "s", "tool_use_id": "u1"}))
            self.assertIn("pending-u1", self.markers())
        finally:
            self.restore_guard_env(old)

    def test_symlinked_state_path_refuses_and_reset_repairs(self):
        target = os.path.join(os.path.dirname(self.dir), "target")
        os.makedirs(target, exist_ok=True)
        os.symlink(target, self.dir)
        guard = self.probe_guard()
        old = self.guard_probe_env()
        try:
            reason = guard.reserve_paid_deny_reason("worker", {"session_id": "s", "tool_use_id": "u1"})
            self.assertIsNotNone(reason)
            self.assertIn("reset", reason)
            self.assertNotIn("symlink", reason)
            self.assertIn("not a real directory", reason)
            proc = run("", self.dir, args=["reset"])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("removed state", proc.stdout)
            self.assertFalse(os.path.islink(self.dir))
            self.assertTrue(os.path.isdir(self.dir))
            self.assertEqual(os.stat(self.dir).st_mode & 0o777, 0o700)
            self.assertIsNone(guard.reserve_paid_deny_reason("worker",
                                                             {"session_id": "s", "tool_use_id": "u1"}))
        finally:
            self.restore_guard_env(old)

    def test_lock_held_by_another_process_refuses_within_three_seconds(self):
        os.makedirs(self.dir, exist_ok=True)
        fd = os.open(os.path.join(self.dir, ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        guard = self.probe_guard()
        old = self.guard_probe_env()
        try:
            started = time.monotonic()
            reason = guard.reserve_paid_deny_reason("worker", {"session_id": "s", "tool_use_id": "u1"})
            elapsed = time.monotonic() - started
            self.assertIsNotNone(reason)
            self.assertIn("reset", reason)
            self.assertLess(elapsed, 3.0)
            fcntl.flock(fd, fcntl.LOCK_UN)
            self.assertIsNone(guard.reserve_paid_deny_reason("worker",
                                                             {"session_id": "s", "tool_use_id": "u1"}))
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
            self.restore_guard_env(old)

    def test_reserved_entry_is_labeled_and_clear_all_may_release_it(self):
        old = self.guard_probe_env()
        try:
            self.assertEqual(self.mod.reserve_paid_agent("worker", "s", "use1"), [])
            guard = self.probe_guard()
            reason = guard.paid_running_deny_reason(None)
            self.assertIn("reserved, not started", reason)
            self.assertIn("clear --all", reason)
            self.assertNotIn("running worker", reason)
            proc = run("", self.dir, args=["clear", "use1"])
            self.assertEqual(proc.stdout.strip(), "1")
            self.assertNotIn("pending-use1", self.markers())
        finally:
            self.restore_guard_env(old)

    def test_clear_one_removes_the_matching_pending_file(self):
        run(start("a1"), self.dir)
        self.assertEqual(run("", self.dir, args=["clear", "a1"]).stdout.strip(), "1")
        self.assertEqual(self.markers(), [])
        self.assertEqual(run("", self.dir, args=["clear", "a1"]).stdout.strip(), "0")
        self.put_raw("pending-a2", json.dumps({"kind": "pending", "agent_type": "worker",
                                               "session_id": "s", "ts": time.time()}))
        self.assertEqual(run("", self.dir, args=["clear", "a2"]).stdout.strip(), "1")
        self.assertEqual(self.markers(), [])

    def test_reset_removes_every_entry_type_and_prints_what_it_removed(self):
        outside = os.path.join(os.path.dirname(self.dir), "outside")
        with open(outside, "w") as fh:
            fh.write("keep")
        os.makedirs(self.dir, exist_ok=True)
        os.makedirs(os.path.join(self.dir, "subdir"))
        with open(os.path.join(self.dir, "subdir", "inner"), "w") as fh:
            fh.write("inner")
        with open(os.path.join(self.dir, "file"), "w") as fh:
            fh.write("f")
        with open(os.path.join(self.dir, ".lock"), "w") as fh:
            fh.write("old")
        os.symlink(outside, os.path.join(self.dir, "link"))
        os.mkfifo(os.path.join(self.dir, "fifo"))
        proc = run("", self.dir, args=["reset"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("removed file", proc.stdout)
        self.assertIn("removed subdir/", proc.stdout)
        self.assertIn("removed link", proc.stdout)
        self.assertIn("removed fifo", proc.stdout)
        self.assertIn("removed .lock", proc.stdout)
        self.assertIn("recreated", proc.stdout)
        self.assertTrue(os.path.isdir(self.dir))
        self.assertEqual(os.stat(self.dir).st_mode & 0o777, 0o700)
        self.assertTrue(os.path.exists(outside))

    def test_idle_check_recomputes_the_transcript_path_from_the_marker(self):
        old = self.guard_probe_env()
        try:
            transcript_dir = os.path.join(os.path.dirname(self.dir), "projects", "p")
            payload = {"hook_event_name": "SubagentStart", "session_id": "s1",
                       "agent_id": "a1", "agent_type": "worker",
                       "transcript_path": os.path.join(transcript_dir, "s1.jsonl")}
            self.mod.on_start(payload)
            with open(os.path.join(self.dir, "a1"), encoding="ascii") as fh:
                rec = json.load(fh)
            self.assertNotIn("agent_id", rec)
            self.assertNotIn("agent_transcript_path", rec)
            self.assertEqual(rec["main_transcript_dir"], transcript_dir)
            rec2 = dict(rec)
            rec2["agent_id"] = "a1"
            agent_path = os.path.join(transcript_dir, "s1", "subagents", "agent-a1.jsonl")
            self.assertEqual(self.mod._recomputed_transcript(rec2), agent_path)
            os.makedirs(os.path.dirname(agent_path), exist_ok=True)
            with open(agent_path, "w") as fh:
                fh.write("done")
            old_ts = time.time() - 21 * 60
            os.utime(agent_path, (old_ts, old_ts))
            self.assertEqual(self.mod.running_paid_agents(), [])
            self.assertFalse(os.path.exists(os.path.join(self.dir, "a1")))
        finally:
            self.restore_guard_env(old)

    def test_idle_check_uses_file_name_and_keeps_symlinked_transcript_live(self):
        os.environ["CBOX_SUBSCRIPTION_PROFILE"] = "low"
        transcript_dir = os.path.join(os.path.dirname(self.dir), "projects")
        payload = json.loads(start("a1"))
        payload["transcript_path"] = os.path.join(transcript_dir, "s1.jsonl")
        self.mod.on_start(payload)
        path = os.path.join(transcript_dir, "s1", "subagents", "agent-a1.jsonl")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        other = os.path.join(os.path.dirname(self.dir), "other.jsonl")
        pathlib.Path(other).write_text("old", encoding="ascii")
        old = time.time() - 21 * 60
        os.utime(other, (old, old))
        with open(os.path.join(self.dir, "a1"), encoding="ascii") as fh:
            rec = json.load(fh)
        rec["agent_id"] = "other"
        rec["agent_transcript_path"] = other
        with open(os.path.join(self.dir, "a1"), "w", encoding="ascii") as fh:
            json.dump(rec, fh)
        self.assertEqual([r["agent_id"] for r in self.mod.running_paid_agents()], ["a1"])
        os.symlink(other, path)
        self.assertEqual([r["agent_id"] for r in self.mod.running_paid_agents()], ["a1"])
        self.assertTrue(os.path.exists(other))

    def test_missing_or_odd_transcript_metadata_keeps_the_marker_live(self):
        os.environ["CBOX_PAID_AGENT_DIR"] = self.dir
        transcript_dir = os.path.join(os.path.dirname(self.dir), "projects", "p")
        outside = os.path.join(os.path.dirname(self.dir), "outside")
        with open(outside, "w") as fh:
            fh.write("keep")
        os.makedirs(transcript_dir, exist_ok=True)
        os.symlink(outside, os.path.join(transcript_dir, "s1.jsonl"))
        cases = [
            ("no metadata", json.dumps({"agent_id": "a1", "agent_type": "worker", "ts": time.time()})),
            ("missing session", json.dumps({"agent_id": "a1", "agent_type": "worker",
                                            "main_transcript_dir": "/x", "ts": time.time()})),
            ("missing agent", json.dumps({"agent_id": "a1", "agent_type": "worker",
                                          "main_transcript_dir": "/x", "session_id": "s",
                                          "ts": time.time()})),
            ("non-string dir", json.dumps({"agent_id": "a1", "agent_type": "worker",
                                           "main_transcript_dir": 5, "session_id": "s",
                                           "ts": time.time()})),
            ("path outside base", json.dumps({"agent_id": "a1", "agent_type": "worker",
                                              "main_transcript_dir": "/x",
                                              "session_id": "../s",
                                              "ts": time.time()})),
            ("dir is a symlink", json.dumps({"agent_id": "a1", "agent_type": "worker",
                                             "main_transcript_dir": os.path.dirname(self.dir),
                                             "session_id": "s",
                                             "ts": time.time()})),
            ("main transcript file is a symlink", json.dumps({"agent_id": "a1", "agent_type": "worker",
                                                              "main_transcript_dir": transcript_dir,
                                                              "session_id": "s1",
                                                              "ts": time.time()})),
            ("dir is a symlink to a real tree", json.dumps({"agent_id": "a1", "agent_type": "worker",
                                                           "main_transcript_dir": os.path.dirname(self.dir),
                                                           "session_id": "s",
                                                           "ts": time.time()})),
        ]
        for name, raw in cases:
            with self.subTest(case=name):
                self.put_raw("a1", raw)
                live = self.mod.running_paid_agents()
                self.assertEqual([r["agent_id"] for r in live], ["a1"])
                self.assertTrue(os.path.exists(os.path.join(self.dir, "a1")))
        with self.subTest(case="symlinked main transcript leaves the target untouched"):
            self.put_raw("a1", json.dumps({"agent_type": "worker",
                                           "main_transcript_dir": transcript_dir,
                                           "session_id": "s1", "ts": time.time()}))
            agent_path = os.path.join(transcript_dir, "s1", "subagents", "agent-a1.jsonl")
            os.makedirs(os.path.dirname(agent_path), exist_ok=True)
            with open(agent_path, "w") as fh:
                fh.write("done")
            old_ts = time.time() - 21 * 60
            os.utime(agent_path, (old_ts, old_ts))
            self.assertEqual(self.mod.running_paid_agents(), [])
            self.assertFalse(os.path.exists(os.path.join(self.dir, "a1")))
            self.assertTrue(os.path.islink(os.path.join(transcript_dir, "s1.jsonl")))
            with open(outside, "rb") as fh:
                self.assertEqual(fh.read(), b"keep")


if __name__ == "__main__":
    unittest.main()
