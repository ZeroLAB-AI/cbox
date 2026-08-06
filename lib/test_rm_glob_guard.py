#!/usr/bin/env python3
import json
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GUARD = ROOT / "etc" / "hooks" / "rm_glob_guard.py"

DENIED = [
    "rm -f *",
    "rm -rf *",
    "rm -f *.tmp",
    "cd /tmp/x && rm -f *",
    "cd /a && rm -f * ; touch b",
    "rm -rf ./*",
    "rm -rf ../*",
    "rm -f ~/*",
    "true | rm -f *",
    "rm -f -- *",
    'rm -f -- "$dir"/*',
    'rm -rf "$TMPBASE"',
    'WT=/zerolab/wt\nFOREIGN=$(git -C /zerolab diff --name-only | head -1)\nrm "$WT/$FOREIGN"',
    'd=$(mktemp -d); rm -rf "$d"',
    'rm -rf "$UNSET_DIR/build"',
    'X=; rm -rf "$X/y"',
    'WT=/a/b; rm -rf "${WT%/}/x"',
    "rm -rf `find /tmp -name x`",
    'rm -rf "$(mktemp -d)"',
    'rel=scratch/dir; rm -rf "$rel"',
    'rm "$d"; d=/tmp/scratch/late',
]

ALLOWED = [
    "rm -rf /tmp/scratch/globtest",
    "rm -f /abs/path/*.log",
    'd=/tmp/scratch/dir; rm -rf -- "$d"',
    'dir=/a/b && rm -f -- "$dir"/*',
    'WT=/zerolab/wt; rm -f "$WT/file.txt"',
    'rm -rf "$HOME/.cache/thing"',
    "git rm -f something",
    "echo rm -f *",
    "rm -rf build",
    "ls *",
    "",
]


def run(command, tool="Bash"):
    payload = {"tool_name": tool, "tool_input": {"command": command}}
    return subprocess.run(
        ["python3", str(GUARD)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=20,
    )


class RmGlobGuardTests(unittest.TestCase):
    def test_bare_and_cwd_relative_globs_are_denied(self):
        for command in DENIED:
            with self.subTest(command=command):
                proc = run(command)
                self.assertEqual(proc.returncode, 2, proc.stderr)
                self.assertIn("rm-glob-guard", proc.stderr)

    def test_anchored_targets_and_unrelated_commands_pass(self):
        for command in ALLOWED:
            with self.subTest(command=command):
                proc = run(command)
                self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_denial_message_names_the_offending_argument(self):
        proc = run("rm -f *.bak")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("*.bak", proc.stderr)
        self.assertIn("rm -rf -- /abs/path/dir", proc.stderr)

    def test_denial_message_examples_pass_the_guard_themselves(self):
        for command in (
            "rm -rf -- /abs/path/dir",
            "rm -f -- /abs/path/dir/*",
            'd=/abs/path/dir; rm -f -- "$d"/*',
        ):
            with self.subTest(command=command):
                proc = run(command)
                self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_possibly_empty_variable_reason_is_specific(self):
        proc = run('WT=/a; F=$(true | head -1); rm "$WT/$F"')
        self.assertEqual(proc.returncode, 2)
        self.assertIn("possibly empty", proc.stderr)

    def test_other_tools_are_untouched(self):
        proc = run("rm -f *", tool="Write")
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_malformed_payload_does_not_block(self):
        proc = subprocess.run(
            ["python3", str(GUARD)],
            input="not json",
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(proc.returncode, 0)

    def test_unbalanced_quotes_do_not_block(self):
        proc = run("rm -f 'unterminated")
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
