#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GATE = ROOT / "etc" / "hooks" / "rm_permission_gate.py"

HOME = "/home/tester"
CWD = "/zerolab/project"


def run_gate(payload, home=HOME):
    env = dict(os.environ)
    env["HOME"] = home
    proc = subprocess.run(
        ["python3", str(GATE)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )
    return proc


def bash_payload(command, kind="critical_path", cwd=CWD):
    payload = {
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": cwd,
    }
    if kind is not None:
        payload["permission_kind"] = kind
    return payload


def decision(proc):
    if not proc.stdout.strip():
        return None
    data = json.loads(proc.stdout)
    return data["hookSpecificOutput"]["decision"]["behavior"]


ALLOWED = [
    "rm -f /tmp_out_a.txt",
    "rm -f -- /tmp_out_a.txt",
    "rm -rf /tmp/scratch/dir",
    "rm -f /abs/path/*.log",
    'd=/tmp/scratch/dir; rm -rf -- "$d"',
    'rm -rf "$HOME/.cache/thing"',
    "rm -f ~/notes/draft.txt",
    "rmdir /tmp/scratch/emptydir",
    "echo start && rm -f /tmp_out_a.txt && echo done",
    "rm -f /no-such-root-entry",
    "rm --interactive=never /tmp/scratch/x",
    "env rm -f /tmp/scratch/x",
    "FOO=bar rm -f /tmp/scratch/x",
]

DENIED = [
    "rm -rf /",
    "rm -rf //",
    "rm -rf /usr",
    "rm -rf /usr/",
    "rm -rf /usr/..",
    "rm -rf /tmp/*",
    'rm -rf "$HOME"',
    "rm -rf ~",
    "rm -rf %s" % CWD,
    "rm -rf /zerolab",
    "rm -f relative/path.txt",
    'rm -rf "$UNSET/x"',
    "rm -rf $(mktemp -d)",
    "rm -rf `find /tmp -name x`",
    "rm -rf /no-such-root-entry",
    "rm -d /no-such-root-entry",
    "rmdir -p /tmp/a/b",
    "rmdir --parents /tmp/a/b",
    "rm -i /tmp/scratch/x",
    "rm -I /tmp/scratch/x",
    "rm --interactive=always /tmp/scratch/x",
    "rm -rf /{usr,etc}",
    'rm -rf "$HOME/.claude/hooks/guard.py"',
    "rm -rf ~/.codex/sessions/x",
    "rm -rf ~/.claude-cbox/projects/p",
    "sudo rm -rf /usr",
    "env rm -rf /usr",
    "FOO=bar rm -rf /usr",
]


class RmPermissionGateTest(unittest.TestCase):
    def test_allowed_commands(self):
        for command in ALLOWED:
            with self.subTest(command=command):
                proc = run_gate(bash_payload(command))
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(decision(proc), "allow", proc.stderr)

    def test_denied_commands(self):
        for command in DENIED:
            with self.subTest(command=command):
                proc = run_gate(bash_payload(command))
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(decision(proc), "deny", proc.stderr)

    def test_top_level_directory_requires_existing_dir(self):
        proc = run_gate(bash_payload("rm -rf /tmp"))
        self.assertEqual(decision(proc), "deny", proc.stderr)

    def test_parent_of_cwd_denied(self):
        proc = run_gate(bash_payload("rm -rf /zerolab", cwd="/zerolab/project/sub"))
        self.assertEqual(decision(proc), "deny", proc.stderr)

    def test_inside_cwd_allowed(self):
        proc = run_gate(bash_payload("rm -rf /zerolab/project/build"))
        self.assertEqual(decision(proc), "allow", proc.stderr)

    def test_non_bash_tool_silent(self):
        payload = bash_payload("rm -rf /")
        payload["tool_name"] = "Write"
        proc = run_gate(payload)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(decision(proc), None)

    def test_standard_kind_silent(self):
        proc = run_gate(bash_payload("rm -rf /", kind="standard"))
        self.assertEqual(decision(proc), None)

    def test_missing_kind_still_gates(self):
        proc = run_gate(bash_payload("rm -f /tmp_out_a.txt", kind=None))
        self.assertEqual(decision(proc), "allow", proc.stderr)

    def test_no_rm_in_command_silent(self):
        proc = run_gate(bash_payload("echo hello"))
        self.assertEqual(decision(proc), None)

    def test_garbage_stdin_silent(self):
        env = dict(os.environ)
        env["HOME"] = HOME
        proc = subprocess.run(
            ["python3", str(GATE)],
            input="not json",
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")

    def test_mixed_targets_deny_wins(self):
        proc = run_gate(bash_payload("rm -f /tmp_out_a.txt /usr"))
        self.assertEqual(decision(proc), "deny", proc.stderr)

    def test_unparseable_command_denies(self):
        proc = run_gate(bash_payload('rm -f /tmp_out_a.txt "unclosed'))
        self.assertEqual(decision(proc), "deny", proc.stderr)

    def test_intermediate_symlink_resolved(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            link = os.path.join(tmp, "escape")
            os.symlink("/", link)
            proc = run_gate(bash_payload("rm -rf %s/usr" % link))
            self.assertEqual(decision(proc), "deny", proc.stderr)

    def test_final_symlink_not_dereferenced(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            link = os.path.join(tmp, "just-a-link")
            os.symlink("/usr", link)
            proc = run_gate(bash_payload("rm -f %s" % link))
            self.assertEqual(decision(proc), "allow", proc.stderr)

    def test_nonrecursive_rootlevel_file_allowed(self):
        proc = run_gate(bash_payload("rm -f /no-such-root-entry"))
        self.assertEqual(decision(proc), "allow", proc.stderr)

    def test_quoted_separator_in_non_rm_command_silent(self):
        for command in [
            'git commit -m "fix bug; add tests"',
            'echo "hi;bye"',
            "python3 -c \"import os; os.remove('/x')\"",
        ]:
            with self.subTest(command=command):
                proc = run_gate(bash_payload(command, kind=None))
                self.assertEqual(decision(proc), None, proc.stderr)

    def test_unrecognized_wrapper_stays_silent(self):
        proc = run_gate(bash_payload("sudo -u root rm -rf /"))
        self.assertEqual(decision(proc), None, proc.stderr)


if __name__ == "__main__":
    unittest.main()
