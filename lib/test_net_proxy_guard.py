#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GUARD = ROOT / "etc" / "hooks" / "net_proxy_guard.py"

SPEC = importlib.util.spec_from_file_location("net_proxy_guard", GUARD)
GUARD_MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD_MOD)

DENIED = [
    "export ALL_PROXY=http://10.0.0.1:1080",
    "ALL_PROXY=socks5h://x:1080 curl http://target/",
    "env ALL_PROXY=socks5h://x:1080 curl http://target/",
    "declare -x all_proxy=socks5h://x:1080",
    "FOO=1 ALL_PROXY=2 curl http://target/",
    "export all_proxy",
    "typeset -x ALL_PROXY=socks5h://x:1080",
    "true; export ALL_PROXY=1",
    "true && export ALL_PROXY=1",
    "true\nexport ALL_PROXY=1",
    "/usr/bin/env ALL_PROXY=1 curl http://target/",
    "export FOO=1 ALL_PROXY=2",
]

ALLOWED = [
    'echo "$ALL_PROXY"',
    "echo ${all_proxy}",
    "unset ALL_PROXY",
    "grep -n 'ALL_PROXY=' file.txt",
    "sed -n '/ALL_PROXY=/p' file.txt",
    "git commit -m \"note ALL_PROXY=1 here\"",
    "env -u ALL_PROXY curl http://target/",
    "cat <<'EOF' > file.txt\nALL_PROXY=http://evil\nEOF",
    "curl --proxy socks5h://cbox-proxy-internal:1080 http://target/",
    "export -n ALL_PROXY",
    "export -p",
    "export -p ALL_PROXY",
    "declare -p ALL_PROXY",
    "declare +x ALL_PROXY",
    'sh -c "echo hi; export ALL_PROXY=1"',
    'bash -c "export ALL_PROXY=1"',
    "python3 -c \"print('export ALL_PROXY=1')\"",
    "",
]


def run(command, tool="Bash", netmap=None, env_overrides=None):
    payload = {"tool_name": tool, "tool_input": {"command": command}}
    env = dict(os.environ)
    if netmap is not None:
        env["CBOX_NETMAP_FILE"] = netmap
    else:
        env.pop("CBOX_NETMAP_FILE", None)
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(
        ["python3", str(GUARD)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=20,
        env=env,
    )


class NetProxyGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.netmap = os.path.join(self.tmp.name, "netmap.json")
        with open(self.netmap, "w") as f:
            f.write("{}")

    def tearDown(self):
        self.tmp.cleanup()

    def _deny(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        out = data["hookSpecificOutput"]
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("CBOX_SOCKS_PROXY", out["permissionDecisionReason"])

    def _allow(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_denied_patterns_with_active_map(self):
        for command in DENIED:
            with self.subTest(command=command):
                proc = run(command, netmap=self.netmap)
                self._deny(proc)

    def test_allowed_patterns_with_active_map(self):
        for command in ALLOWED:
            with self.subTest(command=command):
                proc = run(command, netmap=self.netmap)
                self._allow(proc)

    def test_missing_netmap_allows_everything(self):
        missing = os.path.join(self.tmp.name, "does-not-exist.json")
        for command in DENIED:
            with self.subTest(command=command):
                proc = run(command, netmap=missing)
                self._allow(proc)

    def test_default_path_used_when_env_unset(self):
        proc = run("export ALL_PROXY=1", netmap=None)
        self._allow(proc)

    def test_non_bash_tool_is_untouched(self):
        proc = run("export ALL_PROXY=1", tool="Write", netmap=self.netmap)
        self._allow(proc)

    def test_malformed_payload_does_not_block(self):
        env = dict(os.environ)
        env["CBOX_NETMAP_FILE"] = self.netmap
        proc = subprocess.run(
            ["python3", str(GUARD)],
            input="not valid json {",
            capture_output=True,
            text=True,
            timeout=20,
            env=env,
        )
        self._allow(proc)

    def test_empty_command_does_not_block(self):
        proc = run("", netmap=self.netmap)
        self._allow(proc)

    def test_set_a_is_out_of_scope(self):
        proc = run("set -a", netmap=self.netmap)
        self._allow(proc)

    def test_source_file_with_all_proxy_assignment_denied(self):
        path = os.path.join(self.tmp.name, "envfile.sh")
        with open(path, "w") as f:
            f.write("#!/bin/sh\nexport ALL_PROXY=http://evil:1\n")
        proc = run("source %s" % path, netmap=self.netmap)
        self._deny(proc)
        proc = run(". %s" % path, netmap=self.netmap)
        self._deny(proc)

    def test_source_file_with_lowercase_all_proxy_assignment_denied(self):
        path = os.path.join(self.tmp.name, "envfile_lower.sh")
        with open(path, "w") as f:
            f.write("all_proxy=http://evil:1\n")
        proc = run("source %s" % path, netmap=self.netmap)
        self._deny(proc)

    def test_source_file_without_all_proxy_assignment_allowed(self):
        path = os.path.join(self.tmp.name, "envfile_clean.sh")
        with open(path, "w") as f:
            f.write("#!/bin/sh\necho hello\n")
        proc = run("source %s" % path, netmap=self.netmap)
        self._allow(proc)

    def test_source_missing_file_does_not_block(self):
        path = os.path.join(self.tmp.name, "does-not-exist.sh")
        proc = run("source %s" % path, netmap=self.netmap)
        self._allow(proc)

    def test_interpreter_c_body_not_scanned(self):
        for command in [
            'sh -c "echo hi; export ALL_PROXY=1"',
            'bash -c "export ALL_PROXY=1"',
            "python3 -c \"print('ALL_PROXY=1')\"",
        ]:
            with self.subTest(command=command):
                proc = run(command, netmap=self.netmap)
                self._allow(proc)


class InterpreterCRedosTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.netmap = os.path.join(self.tmp.name, "netmap.json")
        with open(self.netmap, "w") as f:
            f.write("{}")

    def tearDown(self):
        self.tmp.cleanup()

    def test_many_backslashes_do_not_cause_catastrophic_backtracking(self):
        command = "bash -c '" + ("\\" * 5000)
        start = time.monotonic()
        GUARD_MOD.command_sets_all_proxy(command)
        elapsed = time.monotonic() - start
        self.assertLess(elapsed, 0.2)

    def test_many_backslashes_unterminated_quote_via_hook(self):
        command = "bash -c '" + ("\\" * 5000)
        start = time.monotonic()
        proc = run(command, netmap=self.netmap)
        elapsed = time.monotonic() - start
        self.assertLess(elapsed, 5.0)
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
