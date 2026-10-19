#!/usr/bin/env python3
import io
import json
import os
import stat
import sys
import tempfile
import textwrap
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

for _name in list(os.environ):
    if _name.startswith("CBOX_"):
        del os.environ[_name]

import cbox_model_check as mc

DAY = 24 * 3600
NOW = 1_800_000_000


def cid(family, major, minor=None, date=None, one_m=False):
    parts = ["claude", family, str(major)]
    if minor is not None:
        parts.append(str(minor))
    if date:
        parts.append(date)
    return "-".join(parts) + ("[1m]" if one_m else "")


def gid(major, tier, minor=None):
    return "gpt-%s%s-%s" % (major, "" if minor is None else ".%s" % minor, tier)


DEFAULTS = {
    "CBOX_MODEL_OPUS": cid("opus", 5, 5, one_m=True),
    "CBOX_MODEL_HAIKU": cid("haiku", 5, 5),
    "CBOX_MODEL_FABLE": cid("opus", 5, 5, one_m=True),
    "CBOX_MODEL_CODEX_SOL": gid(6, "sol"),
    "CBOX_MODEL_CODEX_LUNA": gid(6, "luna"),
    "CBOX_MODEL_CODEX_ASTRA": gid(6, "astra"),
}


class Boom(Exception):
    pass


class Harness:
    def __init__(self, tmp, answers=(), claude_ids=None, codex_entries=None, tty=True,
                 claude_error=None, codex_error=None, running=True, set_ok=True):
        self.state_path = os.path.join(tmp, "cfg", "model-updates.json")
        self.answers = list(answers)
        self.prompts = []
        self.claude_calls = 0
        self.codex_calls = 0
        self.sets = []
        self.claude_ids = claude_ids
        self.codex_entries = codex_entries
        self.tty = tty
        self.claude_error = claude_error
        self.codex_error = codex_error
        self.running = running
        self.set_ok = set_ok
        self.out = io.StringIO()
        self.err = io.StringIO()

    def _input(self, prompt):
        self.prompts.append(prompt)
        if not self.answers:
            return None
        return self.answers.pop(0)

    def _claude(self):
        self.claude_calls += 1
        if self.claude_error:
            raise self.claude_error
        return self.claude_ids

    def _codex(self):
        self.codex_calls += 1
        if self.codex_error:
            raise self.codex_error
        return self.codex_entries

    def _set(self, key, value):
        self.sets.append((key, value))
        return (True, "") if self.set_ok else (False, "refused")

    def run(self, mode="start", now=NOW, env=None, prefix=("compose",)):
        return mc.run(
            mode, dict(env or {}), self.state_path, "/cbox", list(prefix), now=now, tty=self.tty,
            input_fn=self._input, out=self.out, err=self.err, claude_lister=self._claude,
            codex_lister=self._codex, config_setter=self._set, running_probe=lambda p: self.running,
            defaults=DEFAULTS,
        )

    def state(self):
        return mc.load_state(self.state_path)


class VersionTests(unittest.TestCase):
    def test_claude_parse(self):
        p = mc.parse_claude_id(cid("opus", 4, 5, "20251101"))
        self.assertEqual((p["family"], p["version"], p["date"], p["one_m"]), ("opus", (4, 5), "20251101", False))
        p = mc.parse_claude_id(cid("opus", 5, 5, one_m=True))
        self.assertEqual((p["version"], p["one_m"], p["base"]), ((5, 5), True, cid("opus", 5, 5)))
        p = mc.parse_claude_id(cid("sonnet", 4, None, "20250514"))
        self.assertEqual((p["version"], p["date"]), ((4, 0), "20250514"))
        self.assertEqual(mc.parse_claude_id(cid("haiku", 5))["version"], (5, 0))
        self.assertIsNone(mc.parse_claude_id("-".join(("claude", "3", "5", "sonnet", "20241022"))))
        self.assertIsNone(mc.parse_claude_id(gid(6, "sol")))
        self.assertIsNone(mc.parse_claude_id(None))

    def test_claude_candidate_picks_newest_same_family(self):
        ids = [
            cid("opus", 5, 5), cid("opus", 5, 6), cid("opus", 5, 7), cid("opus", 4, 9),
            cid("sonnet", 6, 0), cid("haiku", 6, 0), cid("fable", 6, 0),
        ]
        self.assertEqual(mc.claude_candidate(cid("opus", 5, 5, one_m=True), ids), cid("opus", 5, 7, one_m=True))
        self.assertEqual(mc.claude_candidate(cid("haiku", 5, 5), ids), cid("haiku", 6, 0))
        self.assertIsNone(mc.claude_candidate(cid("opus", 5, 7), ids))

    def test_claude_candidate_major_beats_minor(self):
        ids = [cid("opus", 5, 9), cid("opus", 6), cid("opus", 6, 1)]
        self.assertEqual(mc.claude_candidate(cid("opus", 5, 5), ids), cid("opus", 6, 1))

    def test_claude_candidate_date_suffix(self):
        ids = [cid("opus", 5, 6, "20261001"), cid("opus", 5, 6), cid("opus", 4, 7, "20251101")]
        self.assertEqual(mc.claude_candidate(cid("opus", 5, 5), ids), cid("opus", 5, 6))
        only_dated = [cid("opus", 5, 6, "20261001"), cid("opus", 5, 6, "20261101")]
        self.assertEqual(mc.claude_candidate(cid("opus", 5, 5), only_dated), cid("opus", 5, 6, "20261101"))
        older_dated = [cid("opus", 4, 5, "20251101")]
        self.assertIsNone(mc.claude_candidate(cid("opus", 5, 5), older_dated))

    def test_claude_candidate_never_offers_banned_release(self):
        ids = [cid("fable", 5, 1), cid("fable", 5, 1, "20260901")]
        self.assertIsNone(mc.claude_candidate(cid("fable", 5), ids))
        self.assertEqual(mc.claude_candidate(cid("fable", 5), ids + [cid("fable", 5, 2)]), cid("fable", 5, 2))

    def test_fable_slot_uses_family_of_its_pin(self):
        ids = [cid("opus", 5, 6), cid("fable", 6)]
        self.assertEqual(mc.claude_candidate(cid("opus", 5, 5, one_m=True), ids), cid("opus", 5, 6, one_m=True))

    def test_claude_candidate_ignores_suffixed_listing_ids_and_junk(self):
        ids = [cid("opus", 5, 6, one_m=True), 7, None, "-".join(("claude", "opus")), "opus-5-6"]
        self.assertIsNone(mc.claude_candidate(cid("opus", 5, 5), ids))
        self.assertIsNone(mc.claude_candidate("custom-pin", [cid("opus", 9)]))

    def test_codex_parse(self):
        p = mc.parse_codex_id(gid(6, "sol", 1))
        self.assertEqual((p["version"], p["tier"]), ((6, 1), "sol"))
        self.assertEqual(mc.parse_codex_id(gid(6, "sol"))["version"], (6, 0))
        self.assertIsNone(mc.parse_codex_id("gpt-reserve"))
        self.assertIsNone(mc.parse_codex_id("codex-auto-review"))
        self.assertIsNone(mc.parse_codex_id(gid(6, "Sol")))

    def test_codex_candidate(self):
        entries = [
            {"id": gid(6, "sol", 1), "hidden": False, "isDefault": True},
            {"id": gid(6, "sol")}, {"id": gid(6, "astra")}, {"id": gid(6, "luna")},
            {"id": gid(5, "sol", 6)}, {"id": "gpt-reserve", "hidden": True},
            {"id": "codex-auto-review", "hidden": True},
        ]
        self.assertEqual(mc.codex_candidate(gid(6, "sol"), entries), gid(6, "sol", 1))
        self.assertIsNone(mc.codex_candidate(gid(6, "astra"), entries))
        self.assertIsNone(mc.codex_candidate(gid(6, "luna"), entries))

    def test_codex_candidate_skips_hidden_and_takes_newest(self):
        entries = [
            {"id": gid(7, "sol"), "hidden": True},
            {"id": gid(6, "sol", 2)}, {"id": gid(6, "sol", 10)}, {"id": gid(6, "sol", 3)},
        ]
        self.assertEqual(mc.codex_candidate(gid(6, "sol", 1), entries), gid(6, "sol", 10))
        self.assertIsNone(mc.codex_candidate("custom", entries))
        self.assertIsNone(mc.codex_candidate(gid(6, "sol", 10), entries))


class StateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "cfg", "model-updates.json")

    def test_missing_and_corrupt_state_read_as_empty(self):
        self.assertEqual(mc.load_state(self.path), mc.new_state())
        os.makedirs(os.path.dirname(self.path))
        for body in ("not json", "[]", json.dumps({"schema": 2}), json.dumps({"schema": 1, "decisions": 5})):
            with open(self.path, "w") as fh:
                fh.write(body)
            self.assertEqual(mc.load_state(self.path)["decisions"], {})

    def test_save_is_atomic_private_and_round_trips(self):
        state = mc.new_state()
        state["last_check"] = NOW
        state["decisions"]["opus"] = {"candidate": "x", "decision": "no", "ts": NOW}
        mc.save_state(self.path, state)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode), 0o700)
        self.assertEqual(os.listdir(os.path.dirname(self.path)), ["model-updates.json"])
        with open(self.path) as fh:
            raw = json.load(fh)
        self.assertEqual(set(raw), {"schema", "last_check", "decisions"})
        self.assertEqual(raw["schema"], 1)
        self.assertEqual(mc.load_state(self.path), state)

    def test_invalid_decisions_are_dropped(self):
        os.makedirs(os.path.dirname(self.path))
        bad = {"schema": 1, "last_check": NOW, "decisions": {
            "opus": {"candidate": "a", "decision": "maybe", "ts": 1},
            "haiku": {"candidate": "b", "decision": "never", "ts": 2},
            "fable": "x",
        }}
        with open(self.path, "w") as fh:
            json.dump(bad, fh)
        self.assertEqual(list(mc.load_state(self.path)["decisions"]), ["haiku"])

    def test_throttle_window(self):
        state = mc.new_state()
        self.assertTrue(mc.is_due(state, NOW))
        state["last_check"] = NOW - DAY + 5
        self.assertFalse(mc.is_due(state, NOW))
        state["last_check"] = NOW - DAY
        self.assertTrue(mc.is_due(state, NOW))
        state["last_check"] = NOW + 3600
        self.assertTrue(mc.is_due(state, NOW))


def newer_listing():
    return [cid("opus", 5, 6), cid("haiku", 5, 6), cid("sonnet", 5, 5)]


def newer_codex():
    return [{"id": gid(6, "sol", 1)}, {"id": gid(6, "luna")}]


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def harness(self, **kw):
        return Harness(self.tmp.name, **kw)

    def test_prompt_text_and_three_answers_persist(self):
        h = self.harness(answers=["y", "n", "v", "n"], claude_ids=newer_listing(), codex_entries=newer_codex())
        self.assertEqual(h.run(), 0)
        self.assertEqual(h.prompts[0], "cbox: newer model for opus: %s -> %s. Update? [y]es / [n]o / ne[v]er: " % (
            cid("opus", 5, 5, one_m=True), cid("opus", 5, 6, one_m=True)))
        self.assertEqual([p.split(":")[1].split()[-1] for p in h.prompts],
                         ["opus", "haiku", "fable", "codex-sol"])
        self.assertEqual(h.sets, [("CBOX_MODEL_OPUS", cid("opus", 5, 6, one_m=True))])
        d = h.state()["decisions"]
        self.assertEqual(d["opus"], {"candidate": cid("opus", 5, 6, one_m=True), "decision": "yes", "ts": NOW})
        self.assertEqual(d["haiku"], {"candidate": cid("haiku", 5, 6), "decision": "no", "ts": NOW})
        self.assertEqual(d["fable"], {"candidate": cid("opus", 5, 6, one_m=True), "decision": "never", "ts": NOW})
        self.assertEqual(d["codex-sol"], {"candidate": gid(6, "sol", 1), "decision": "no", "ts": NOW})
        self.assertEqual(h.state()["last_check"], NOW)

    def test_yes_prints_the_host_steps(self):
        h = self.harness(answers=["yes", "n", "n", "y"], claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run(env={"CBOX_CLAUDE_MODE": "mount"})
        text = h.err.getvalue()
        self.assertIn("recreates the container", text)
        self.assertIn("cbox setup update settings", text)
        self.assertIn("cbox setup update mcp-servers", text)
        self.assertIn("CBOX_MODEL_CODEX_SOL=%s" % gid(6, "sol", 1), text)
        h2 = Harness(os.path.join(self.tmp.name, "second"), answers=["y", "n", "n", "n"],
                     claude_ids=newer_listing(), codex_entries=newer_codex())
        h2.run(env={"CBOX_CLAUDE_MODE": "volume"})
        self.assertNotIn("cbox setup update", h2.err.getvalue())
        self.assertIn("recreates the container", h2.err.getvalue())

    def test_forced_yes_names_the_manual_recreate(self):
        h = self.harness(answers=["y", "n", "n", "n"], claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run(mode="check")
        self.assertIn("cbox down && cbox run", h.err.getvalue())
        self.assertIn("cbox down && cbox up", h.err.getvalue())

    def test_codex_only_yes_does_not_claim_a_recreate(self):
        h = self.harness(answers=["n", "n", "n", "y"], claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run(env={"CBOX_CLAUDE_MODE": "volume"})
        self.assertNotIn("recreates", h.err.getvalue())
        self.assertIn("keep the old model until restarted", h.err.getvalue())

    def test_long_answers_and_case(self):
        h = self.harness(answers=["Yes", "NO", "Never", " v "], claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        decisions = [h.state()["decisions"][t]["decision"] for t in ("opus", "haiku", "fable", "codex-sol")]
        self.assertEqual(decisions, ["yes", "no", "never", "never"])

    def test_invalid_answers_skip_without_recording(self):
        h = self.harness(answers=["x", "", "?"], claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        self.assertEqual(len(h.prompts), 3)
        self.assertEqual(h.state()["decisions"], {})
        self.assertEqual(h.sets, [])

    def test_eof_records_nothing(self):
        h = self.harness(answers=[], claude_ids=newer_listing(), codex_entries=newer_codex())
        self.assertEqual(h.run(), 0)
        self.assertEqual(h.state()["decisions"], {})

    def test_interrupt_never_blocks(self):
        h = self.harness(claude_ids=newer_listing(), codex_entries=newer_codex())

        def raiser(prompt):
            raise KeyboardInterrupt()

        h._input = raiser
        self.assertEqual(h.run(), 0)

    def test_never_suppresses_same_candidate_but_not_a_newer_one(self):
        h = self.harness(answers=["v", "v", "v", "v"], claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        h.answers = []
        h.prompts = []
        h.run(mode="check", now=NOW + 5 * DAY)
        self.assertEqual(h.prompts, [])
        h.claude_ids = [cid("opus", 5, 7), cid("haiku", 5, 6)]
        h.answers = ["n", "n"]
        h.run(mode="check", now=NOW + 6 * DAY)
        self.assertEqual(len(h.prompts), 2)
        self.assertIn(cid("opus", 5, 7, one_m=True), h.prompts[0])
        self.assertEqual(h.state()["decisions"]["haiku"]["decision"], "never")

    def test_no_is_asked_again_at_the_next_check(self):
        h = self.harness(answers=["n", "n", "n", "n"], claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        h.prompts = []
        h.answers = ["n"] * 4
        h.run(now=NOW + DAY - 10)
        self.assertEqual(h.prompts, [])
        h.run(now=NOW + DAY + 1)
        self.assertEqual(len(h.prompts), 4)

    def test_no_is_suppressed_inside_the_window_unless_forced(self):
        h = self.harness(answers=["n"] * 4, claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        h.prompts = []
        state = h.state()
        state["last_check"] = 0
        mc.save_state(h.state_path, state)
        h.answers = []
        h.run(now=NOW + 60)
        self.assertEqual(h.prompts, [])
        h.answers = ["n"] * 4
        h.run(mode="check", now=NOW + 120)
        self.assertEqual(len(h.prompts), 4)

    def test_throttle_one_network_check_per_24h(self):
        h = self.harness(answers=["n"] * 4, claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        self.assertEqual((h.claude_calls, h.codex_calls), (1, 1))
        h.run(now=NOW + 3600)
        h.run(now=NOW + DAY - 1)
        self.assertEqual((h.claude_calls, h.codex_calls), (1, 1))
        h.answers = ["n"] * 4
        h.run(now=NOW + DAY)
        self.assertEqual((h.claude_calls, h.codex_calls), (2, 2))

    def test_forced_check_ignores_the_throttle(self):
        h = self.harness(answers=["n"] * 4, claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        h.answers = ["n"] * 4
        h.run(mode="check", now=NOW + 60)
        self.assertEqual(h.claude_calls, 2)

    def test_non_tty_start_is_report_only_and_writes_nothing(self):
        h = self.harness(answers=["n"] * 4, claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        with open(h.state_path) as fh:
            before = fh.read()
        os.utime(h.state_path, (1, 1))
        h2 = self.harness(tty=False, claude_error=Boom("no network call expected"))
        h2.state_path = h.state_path
        self.assertEqual(h2.run(now=NOW + 5 * DAY), 0)
        self.assertEqual((h2.claude_calls, h2.codex_calls, h2.prompts, h2.sets), (0, 0, [], []))
        report = h2.err.getvalue()
        self.assertEqual(report.count("\n"), 1)
        self.assertIn("newer models available", report)
        self.assertIn("opus", report)
        self.assertIn(gid(6, "sol", 1), report)
        with open(h.state_path) as fh:
            self.assertEqual(fh.read(), before)
        self.assertEqual(os.stat(h.state_path).st_mtime, 1)

    def test_non_tty_start_without_pending_offers_is_silent_and_creates_nothing(self):
        h = self.harness(tty=False)
        self.assertEqual(h.run(), 0)
        self.assertEqual(h.err.getvalue(), "")
        self.assertFalse(os.path.exists(h.state_path))
        self.assertFalse(os.path.exists(os.path.dirname(h.state_path)))

    def test_non_tty_report_skips_candidates_already_adopted(self):
        h = self.harness(answers=["n"] * 4, claude_ids=newer_listing(), codex_entries=newer_codex())
        h.run()
        env = {"CBOX_MODEL_OPUS": cid("opus", 5, 6, one_m=True), "CBOX_MODEL_HAIKU": cid("haiku", 5, 6),
               "CBOX_MODEL_FABLE": cid("opus", 5, 6, one_m=True), "CBOX_MODEL_CODEX_SOL": gid(6, "sol", 1)}
        h2 = self.harness(tty=False)
        h2.state_path = h.state_path
        h2.run(env=env)
        self.assertEqual(h2.err.getvalue(), "")

    def test_non_tty_check_command_reports_to_stdout_and_writes_nothing(self):
        h = self.harness(tty=False, claude_ids=newer_listing(), codex_entries=newer_codex())
        self.assertEqual(h.run(mode="check"), 0)
        self.assertIn("newer models available", h.out.getvalue())
        self.assertIn("opus", h.out.getvalue())
        self.assertEqual(h.prompts, [])
        self.assertFalse(os.path.exists(h.state_path))

    def test_failures_never_block_and_produce_one_note(self):
        h = self.harness(claude_error=Boom("boom"), codex_error=Boom("bang"))
        self.assertEqual(h.run(), 0)
        self.assertEqual(h.prompts, [])
        self.assertEqual(h.err.getvalue().count("\n"), 1)
        self.assertIn("cbox: model check:", h.err.getvalue())
        self.assertIn("claude list unavailable", h.err.getvalue())
        self.assertIn("codex list unavailable", h.err.getvalue())

    def test_one_failing_vendor_still_offers_the_other(self):
        h = self.harness(answers=["n"], claude_error=Boom("boom"), codex_entries=newer_codex())
        h.run()
        self.assertEqual(len(h.prompts), 1)
        self.assertIn("codex-sol", h.prompts[0])
        self.assertEqual(h.err.getvalue().count("\n"), 1)

    def test_failed_check_is_throttled_too(self):
        h = self.harness(claude_error=Boom("boom"), codex_error=Boom("bang"))
        h.run()
        h.run(now=NOW + 60)
        self.assertEqual(h.claude_calls, 1)

    def test_container_not_running_defers_codex_without_stamping(self):
        h = self.harness(answers=["n", "n", "n"], claude_ids=newer_listing(), running=False)
        h.run()
        self.assertEqual(h.codex_calls, 0)
        self.assertEqual(h.err.getvalue(), "")
        self.assertEqual(h.state()["last_check"], 0)
        self.assertEqual(len(h.prompts), 3)
        h.prompts = []
        h.running = True
        h.codex_entries = newer_codex()
        h.answers = ["n"]
        h.run(now=NOW + 120)
        self.assertEqual(len(h.prompts), 1)
        self.assertIn("codex-sol", h.prompts[0])
        self.assertEqual(h.state()["last_check"], NOW + 120)

    def test_forced_check_reports_the_deferred_codex_and_stamps(self):
        h = self.harness(answers=["n", "n", "n"], claude_ids=newer_listing(), running=False)
        h.run(mode="check")
        self.assertIn("codex list skipped", h.err.getvalue())
        self.assertEqual(h.state()["last_check"], NOW)

    def test_check_off_skips_everything(self):
        h = self.harness(claude_ids=newer_listing(), codex_entries=newer_codex())
        self.assertEqual(h.run(env={"CBOX_MODEL_CHECK": "off"}), 0)
        self.assertEqual((h.claude_calls, h.codex_calls, h.prompts), (0, 0, []))
        self.assertFalse(os.path.exists(h.state_path))
        h.run(mode="check", env={"CBOX_MODEL_CHECK": "off"})
        self.assertEqual(h.claude_calls, 0)
        self.assertIn("CBOX_MODEL_CHECK=off", h.err.getvalue())

    def test_config_set_failure_is_reported_and_not_recorded(self):
        h = self.harness(answers=["y", "n", "n", "n"], claude_ids=newer_listing(), codex_entries=newer_codex(), set_ok=False)
        self.assertEqual(h.run(), 0)
        self.assertIn("not applied: refused", h.err.getvalue())
        self.assertNotIn("opus", h.state()["decisions"])
        self.assertNotIn("saved", h.err.getvalue())
        h.answers = ["y", "n", "n", "n"]
        self.assertEqual(h.run(mode="check", now=NOW + 10), 1)

    def test_everything_current_prints_nothing_in_start_and_a_line_in_check(self):
        current = [DEFAULTS["CBOX_MODEL_OPUS"][:-4], DEFAULTS["CBOX_MODEL_HAIKU"]]
        h = self.harness(claude_ids=current, codex_entries=[{"id": gid(6, "sol")}])
        h.run()
        self.assertEqual((h.out.getvalue(), h.err.getvalue()), ("", ""))
        h.run(mode="check", now=NOW + 10)
        self.assertIn("all pinned models are current", h.out.getvalue())

    def test_env_pins_override_defaults(self):
        h = self.harness(answers=[], claude_ids=newer_listing(), codex_entries=newer_codex())
        env = {"CBOX_MODEL_OPUS": cid("opus", 5, 6, one_m=True), "CBOX_MODEL_HAIKU": cid("haiku", 5, 6),
               "CBOX_MODEL_FABLE": cid("opus", 5, 6, one_m=True), "CBOX_MODEL_CODEX_SOL": gid(6, "sol", 1)}
        h.run(env=env)
        self.assertEqual(h.prompts, [])


class CodexTransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def stub(self, body):
        path = os.path.join(self.tmp.name, "compose")
        with open(path, "w") as fh:
            fh.write("#!%s\n" % sys.executable + textwrap.dedent(body))
        os.chmod(path, 0o755)
        return [path]

    SERVER = """
        import json, sys
        args = sys.argv[1:]
        if args[:2] == ["ps", "-q"]:
            print("abc123")
            sys.exit(0)
        assert args[:4] == ["exec", "-T", "cbox", "/entrypoint.sh"], args
        assert args[-1] == "exec codex app-server", args
        seen = []
        for line in sys.stdin:
            msg = json.loads(line)
            seen.append(msg.get("method"))
            if msg.get("method") == "initialize":
                assert msg["params"]["clientInfo"]["name"]
                print(json.dumps({"id": msg["id"], "result": {"userAgent": "stub"}}), flush=True)
            elif msg.get("method") == "model/list":
                assert seen == ["initialize", "initialized", "model/list"], seen
                assert msg["params"] == {"includeHidden": True}
                print("not json", flush=True)
                print(json.dumps({"method": "noise", "params": {}}), flush=True)
                print(json.dumps({"id": msg["id"], "result": {"data": [
                    {"id": "%s", "hidden": False, "isDefault": True, "upgrade": None},
                    {"id": "gpt-reserve", "hidden": True},
                    "junk",
                ]}}), flush=True)
    """

    def test_listing_over_a_stub_compose(self):
        prefix = self.stub(self.SERVER % gid(6, "sol", 1))
        self.assertTrue(mc.container_running(prefix))
        entries = mc.list_codex_models(prefix, budget=5)
        self.assertEqual([e["id"] for e in entries], [gid(6, "sol", 1), "gpt-reserve"])
        self.assertEqual(mc.codex_candidate(gid(6, "sol"), entries), gid(6, "sol", 1))

    def test_container_not_running(self):
        prefix = self.stub("import sys\nsys.exit(0)\n")
        self.assertFalse(mc.container_running(prefix))
        self.assertFalse(mc.container_running(["/nonexistent/compose"]))

    def test_silent_server_hits_the_budget(self):
        prefix = self.stub("import sys, time\nsys.stdin.read()\n")
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            mc.list_codex_models(prefix, budget=0.4)
        self.assertLess(time.monotonic() - started, 4)

    def test_dead_server_is_an_error_not_a_hang(self):
        prefix = self.stub("import sys\nsys.exit(3)\n")
        with self.assertRaises(Exception):
            mc.list_codex_models(prefix, budget=3)

    def test_run_uses_the_real_codex_path(self):
        prefix = self.stub(self.SERVER % gid(6, "sol", 1))
        err = io.StringIO()
        answers = iter(["n"])
        state_path = os.path.join(self.tmp.name, "s", "m.json")
        rc = mc.run(
            "start", {}, state_path, "/cbox", prefix, now=NOW, tty=True,
            input_fn=lambda p: next(answers, None), out=io.StringIO(), err=err,
            claude_lister=lambda: [], defaults=DEFAULTS,
        )
        self.assertEqual(rc, 0)
        self.assertEqual(mc.load_state(state_path)["decisions"]["codex-sol"]["candidate"], gid(6, "sol", 1))


class ClaudeTransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old_home = os.environ.get("HOME")
        os.environ["HOME"] = self.tmp.name
        self.addCleanup(self.restore)

    def restore(self):
        if self.old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self.old_home

    def write_creds(self, expires_s, token="tok-123", subdir=".claude"):
        d = os.path.join(self.tmp.name, subdir)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, ".credentials.json"), "w") as fh:
            json.dump({"claudeAiOauth": {"accessToken": token, "expiresAt": int(expires_s * 1000)}}, fh)

    def test_token_read_and_expiry_margin(self):
        self.write_creds(NOW + 3600)
        self.assertEqual(mc.read_token({}, NOW), ("tok-123", ""))
        self.write_creds(NOW + 59)
        self.assertEqual(mc.read_token({}, NOW)[0], None)
        self.write_creds(NOW - 5)
        self.assertEqual(mc.read_token({}, NOW)[0], None)

    def test_token_missing_and_malformed(self):
        self.assertEqual(mc.read_token({}, NOW)[0], None)
        self.write_creds(NOW + 3600, token="has space")
        self.assertEqual(mc.read_token({}, NOW)[0], None)

    def test_securestorage_dir_wins(self):
        self.write_creds(NOW + 3600, token="primary")
        self.write_creds(NOW + 3600, token="secure", subdir="secure")
        env = {"CLAUDE_SECURESTORAGE_CONFIG_DIR": os.path.join(self.tmp.name, "secure")}
        self.assertEqual(mc.read_token(env, NOW)[0], "secure")

    def test_symlinked_credentials_are_refused(self):
        self.write_creds(NOW + 3600, token="real", subdir="elsewhere")
        os.makedirs(os.path.join(self.tmp.name, ".claude"))
        os.symlink(os.path.join(self.tmp.name, "elsewhere", ".credentials.json"),
                   os.path.join(self.tmp.name, ".claude", ".credentials.json"))
        self.assertEqual(mc.read_token({}, NOW)[0], None)

    def test_fetch_sends_the_headers_and_parses(self):
        captured = {}

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self, n):
                return json.dumps({"data": [{"id": cid("opus", 5, 6)}, {"id": 5}, "x"]}).encode()

        class Opener:
            def open(self, req, timeout=None):
                captured["req"] = req
                captured["timeout"] = timeout
                return Resp()

        real = urllib.request.build_opener

        def fake(*handlers):
            captured["handlers"] = handlers
            return Opener()

        urllib.request.build_opener = fake
        try:
            ids = mc.fetch_claude_ids("tok-abc")
        finally:
            urllib.request.build_opener = real
        self.assertEqual(ids, [cid("opus", 5, 6)])
        req = captured["req"]
        self.assertEqual(req.full_url, "https://api.anthropic.com/v1/models?limit=100")
        self.assertEqual(req.get_header("Anthropic-version"), "2023-06-01")
        self.assertEqual(req.get_header("Anthropic-beta"), "oauth-2025-04-20")
        self.assertEqual(req.unredirected_hdrs.get("Authorization"), "Bearer tok-abc")
        self.assertNotIn("Authorization", req.headers)
        self.assertEqual(captured["timeout"], 5)
        self.assertIsNone(captured["handlers"][0].redirect_request(req, None, 302, "", {}, "http://x"))

    def test_fetch_errors_are_plain_runtime_errors(self):
        class Opener:
            def __init__(self, exc):
                self.exc = exc

            def open(self, req, timeout=None):
                raise self.exc

        real = urllib.request.build_opener
        try:
            for exc, text in (
                (urllib.error.HTTPError("u", 401, "m", {}, None), "HTTP 401"),
                (urllib.error.URLError("down"), "network error"),
            ):
                urllib.request.build_opener = lambda *h, e=exc: Opener(e)
                with self.assertRaises(RuntimeError) as ctx:
                    mc.fetch_claude_ids("t")
                self.assertEqual(str(ctx.exception), text)
        finally:
            urllib.request.build_opener = real

    def test_budget_times_out(self):
        with self.assertRaises(TimeoutError):
            mc.with_budget(lambda: time.sleep(5), 0.2)
        self.assertEqual(mc.with_budget(lambda: 7, 1), 7)

    def test_default_lister_without_login_is_a_note_not_a_failure(self):
        err = io.StringIO()
        rc = mc.run("start", {}, os.path.join(self.tmp.name, "s.json"), "/cbox", [], now=NOW, tty=True,
                    input_fn=lambda p: None, out=io.StringIO(), err=err, defaults=DEFAULTS)
        self.assertEqual(rc, 0)
        self.assertIn("no login token", err.getvalue())
        self.assertEqual(err.getvalue().count("\n"), 1)


class CliTests(unittest.TestCase):
    def test_usage_errors(self):
        self.assertEqual(mc.main([]), 2)
        self.assertEqual(mc.main(["bogus", "--cbox", "x"]), 2)
        self.assertEqual(mc.main(["start"]), 2)
        self.assertEqual(mc.main(["start", "--cbox"]), 2)

    def test_registry_defaults_are_parseable_model_ids(self):
        defaults = mc.registry_defaults()
        self.assertEqual(set(defaults), set(k for _, k, _ in mc.TIERS))
        for key, value in defaults.items():
            kind = [kd for _, k, kd in mc.TIERS if k == key][0]
            parsed = mc.parse_claude_id(value) if kind == "claude" else mc.parse_codex_id(value)
            self.assertIsNotNone(parsed, value)

    def test_start_never_raises(self):
        old = os.environ.get("HOME")
        os.environ["HOME"] = tempfile.mkdtemp()
        try:
            self.assertEqual(mc.main(["start", "--cbox", "/cbox", "--state", "/proc/nope/x.json"]), 0)
        finally:
            if old is not None:
                os.environ["HOME"] = old

    def test_run_config_set_reports_failures(self):
        with tempfile.TemporaryDirectory() as d:
            ok = os.path.join(d, "ok")
            bad = os.path.join(d, "bad")
            for path, body in ((ok, "exit 0"), (bad, "echo first >&2; echo 'refused: drifted' >&2; exit 1")):
                with open(path, "w") as fh:
                    fh.write("#!/bin/sh\n" + body + "\n")
                os.chmod(path, 0o755)
            self.assertEqual(mc.run_config_set(ok, "K", "v"), (True, ""))
            self.assertEqual(mc.run_config_set(bad, "K", "v"), (False, "refused: drifted"))
            self.assertEqual(mc.run_config_set(os.path.join(d, "none"), "K", "v")[0], False)


if __name__ == "__main__":
    unittest.main()
