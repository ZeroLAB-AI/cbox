#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GATE = ROOT / "etc" / "hooks" / "spawn_gate.py"


def run(prompt, tool="Agent", state=None, env=None):
    payload = {
        "tool_name": tool,
        "tool_input": {"description": "d", "prompt": prompt},
    }
    e = dict(os.environ)
    if state:
        e["CBOX_SPAWN_GATE_STATE"] = state
    if env:
        e.update(env)
    return subprocess.run(
        ["python3", str(GATE)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=30,
        env=e,
    )


class DecisionGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state.json")

    def test_implementing_spawn_without_a_decision_is_refused(self):
        proc = run("implement the forward table and wire it in", state=self.state)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("name the decision", proc.stderr)

    def test_implementing_spawn_naming_a_ruling_passes(self):
        proc = run("OWNER RULING: sshd in cbox. implement the entry program",
                   state=self.state)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_read_only_work_never_needs_a_decision(self):
        for prompt in (
            "read-only audit: inventory every platform dependency",
            "produce findings only, do not modify any file",
            "research the upstream protocol and report",
        ):
            with self.subTest(prompt=prompt):
                proc = run(prompt, state=self.state)
                self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_other_tools_are_untouched(self):
        proc = run("implement everything", tool="Bash", state=self.state)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_malformed_payload_does_not_block(self):
        proc = subprocess.run(
            ["python3", str(GATE)], input="not json",
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(proc.returncode, 0)


class UnlandedWorkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state.json")

    def test_spawning_stops_once_too_much_is_unlanded(self):
        env = {"CBOX_SPAWN_GATE_MAX_UNLANDED": "3"}
        for _ in range(3):
            proc = run("read-only audit", state=self.state, env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
        proc = run("read-only audit", state=self.state, env=env)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("since the last commit", proc.stderr)

    def test_a_landed_commit_clears_the_counter(self):
        env = {"CBOX_SPAWN_GATE_MAX_UNLANDED": "2"}
        for _ in range(2):
            run("read-only audit", state=self.state, env=env)
        self.assertEqual(run("read-only audit", state=self.state, env=env).returncode, 2)
        with open(self.state, encoding="ascii") as fh:
            saved = json.load(fh)
        saved["head"] = "0" * 40
        with open(self.state, "w", encoding="ascii") as fh:
            json.dump(saved, fh)
        self.assertEqual(run("read-only audit", state=self.state, env=env).returncode, 0)


if __name__ == "__main__":
    unittest.main()
