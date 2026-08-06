import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "etc", "container", "cbox-session-entry.py")
SPEC = importlib.util.spec_from_file_location("cbox_session_entry", PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

ENGINE = "cod" + "ex"
SESSION = "cbox-" + ENGINE + "-0123456789abcdef"


class ParseCommandTests(unittest.TestCase):
    def test_list_accepted(self):
        self.assertEqual(MOD.parse_command("list"), ("list", None))

    def test_attach_accepted(self):
        self.assertEqual(MOD.parse_command("attach %s" % SESSION), ("attach", SESSION))

    def test_spawn_accepted(self):
        self.assertEqual(MOD.parse_command("spawn claude"), ("spawn", "claude"))

    def test_none_rejected(self):
        with self.assertRaises(ValueError):
            MOD.parse_command(None)

    def test_empty_rejected(self):
        with self.assertRaises(ValueError):
            MOD.parse_command("")

    def test_shell_metacharacters_rejected(self):
        payloads = [
            "list; rm -rf /",
            "list && whoami",
            "list `whoami`",
            "list $(whoami)",
            "attach foo; rm -rf /",
            "attach foo | cat",
            "spawn claude; id",
            "list\nattach foo",
        ]
        for payload in payloads:
            with self.assertRaises(ValueError, msg=payload):
                MOD.parse_command(payload)

    def test_flag_shaped_session_rejected(self):
        for payload in ("attach -oProxyCommand=x", "attach --help", "attach -"):
            with self.assertRaises(ValueError, msg=payload):
                MOD.parse_command(payload)

    def test_path_shaped_session_rejected(self):
        for payload in ("attach ../../etc/passwd", "attach /etc/passwd", "attach a/b"):
            with self.assertRaises(ValueError, msg=payload):
                MOD.parse_command(payload)

    def test_unknown_operation_rejected(self):
        for payload in ("delete foo", "list extra", "attach", "spawn"):
            with self.assertRaises(ValueError, msg=payload):
                MOD.parse_command(payload)

    def test_engine_outside_allowlist_rejected(self):
        for payload in ("spawn bash", "spawn sh", "spawn ; rm -rf /"):
            with self.assertRaises(ValueError, msg=payload):
                MOD.parse_command(payload)

    def test_realistic_session_name_accepted(self):
        op, arg = MOD.parse_command("attach cbox-claude-deadbeef")
        self.assertEqual((op, arg), ("attach", "cbox-claude-deadbeef"))


class BuildAttachArgvTests(unittest.TestCase):
    def test_viewer_argv_shape(self):
        argv = MOD.build_attach_argv("viewer", SESSION)
        self.assertEqual(argv, ["tmux", "attach-session", "-r", "-f", "read-only,ignore-size", "-t", SESSION])

    def test_full_attach_argv_shape(self):
        argv = MOD.build_attach_argv("full-attach", SESSION)
        self.assertEqual(argv, ["tmux", "attach-session", "-t", SESSION])

    def test_disabled_refused(self):
        with self.assertRaises(PermissionError):
            MOD.build_attach_argv("disabled", SESSION)

    def test_argv_never_carries_a_flag_beyond_the_fixed_set(self):
        for tier in ("viewer", "full-attach"):
            argv = MOD.build_attach_argv(tier, SESSION)
            allowed = {"tmux", "attach-session", "-r", "-f", "read-only,ignore-size", "-t", SESSION}
            self.assertTrue(set(argv).issubset(allowed), argv)

    def test_argv_never_takes_a_flag_from_the_caller(self):
        malicious_session = "cbox-claude-deadbeefcafebabe"
        argv = MOD.build_attach_argv("full-attach", malicious_session)
        self.assertEqual(argv[-1], malicious_session)
        self.assertNotIn("-oProxyCommand", argv)


class LayerThreeGateTests(unittest.TestCase):
    def test_resolve_tier_missing_file_is_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.path.join(tmp, "does-not-exist")
            old = MOD.ACCESS_FILE
            MOD.ACCESS_FILE = missing
            try:
                self.assertEqual(MOD.resolve_tier(), "disabled")
            finally:
                MOD.ACCESS_FILE = old

    def test_resolve_tier_unreadable_content_is_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "level")
            with open(path, "w", encoding="ascii") as fh:
                fh.write("root-can-do-anything\n")
            old = MOD.ACCESS_FILE
            MOD.ACCESS_FILE = path
            try:
                self.assertEqual(MOD.resolve_tier(), "disabled")
            finally:
                MOD.ACCESS_FILE = old

    def test_resolve_tier_symlink_is_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "target")
            link = os.path.join(tmp, "level")
            with open(target, "w", encoding="ascii") as fh:
                fh.write("full-attach\n")
            os.symlink(target, link)
            old = MOD.ACCESS_FILE
            MOD.ACCESS_FILE = link
            try:
                self.assertEqual(MOD.resolve_tier(), "disabled")
            finally:
                MOD.ACCESS_FILE = old

    def test_resolve_tier_valid_value_is_honored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "level")
            with open(path, "w", encoding="ascii") as fh:
                fh.write("viewer\n")
            old = MOD.ACCESS_FILE
            MOD.ACCESS_FILE = path
            try:
                self.assertEqual(MOD.resolve_tier(), "viewer")
            finally:
                MOD.ACCESS_FILE = old

    def test_level_flip_takes_effect_on_next_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "level")
            old = MOD.ACCESS_FILE
            MOD.ACCESS_FILE = path
            try:
                with open(path, "w", encoding="ascii") as fh:
                    fh.write("disabled\n")
                self.assertEqual(MOD.resolve_tier(), "disabled")
                with open(path, "w", encoding="ascii") as fh:
                    fh.write("full-attach\n")
                self.assertEqual(MOD.resolve_tier(), "full-attach")
            finally:
                MOD.ACCESS_FILE = old

    def test_window_open_missing_file_is_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.path.join(tmp, "does-not-exist")
            old = MOD.WINDOW_FILE
            MOD.WINDOW_FILE = missing
            try:
                self.assertTrue(MOD.window_open())
            finally:
                MOD.WINDOW_FILE = old

    def test_window_open_empty_file_is_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "window")
            open(path, "w", encoding="ascii").close()
            old = MOD.WINDOW_FILE
            MOD.WINDOW_FILE = path
            try:
                self.assertTrue(MOD.window_open())
            finally:
                MOD.WINDOW_FILE = old

    def test_window_open_future_deadline_is_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "window")
            with open(path, "w", encoding="ascii") as fh:
                fh.write(str(int(time.time()) + 600))
            old = MOD.WINDOW_FILE
            MOD.WINDOW_FILE = path
            try:
                self.assertTrue(MOD.window_open())
            finally:
                MOD.WINDOW_FILE = old

    def test_window_open_past_deadline_is_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "window")
            with open(path, "w", encoding="ascii") as fh:
                fh.write(str(int(time.time()) - 600))
            old = MOD.WINDOW_FILE
            MOD.WINDOW_FILE = path
            try:
                self.assertFalse(MOD.window_open())
            finally:
                MOD.WINDOW_FILE = old

    def test_window_open_malformed_content_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "window")
            with open(path, "w", encoding="ascii") as fh:
                fh.write("not-a-number")
            old = MOD.WINDOW_FILE
            MOD.WINDOW_FILE = path
            try:
                self.assertFalse(MOD.window_open())
            finally:
                MOD.WINDOW_FILE = old

    def test_gates_are_independent(self):
        with tempfile.TemporaryDirectory() as tmp:
            level_path = os.path.join(tmp, "level")
            window_path = os.path.join(tmp, "window")
            old_level, old_window = MOD.ACCESS_FILE, MOD.WINDOW_FILE
            MOD.ACCESS_FILE, MOD.WINDOW_FILE = level_path, window_path
            try:
                with open(level_path, "w", encoding="ascii") as fh:
                    fh.write("full-attach\n")
                with open(window_path, "w", encoding="ascii") as fh:
                    fh.write(str(int(time.time()) - 600))
                self.assertEqual(MOD.resolve_tier(), "full-attach")
                self.assertFalse(MOD.window_open())

                with open(level_path, "w", encoding="ascii") as fh:
                    fh.write("disabled\n")
                with open(window_path, "w", encoding="ascii") as fh:
                    fh.write("")
                self.assertEqual(MOD.resolve_tier(), "disabled")
                self.assertTrue(MOD.window_open())
            finally:
                MOD.ACCESS_FILE, MOD.WINDOW_FILE = old_level, old_window


class AuditTests(unittest.TestCase):
    def test_audit_symlink_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "target")
            link = os.path.join(tmp, "audit.jsonl")
            with open(target, "w", encoding="ascii"):
                pass
            os.symlink(target, link)
            old = MOD.AUDIT_PATH
            MOD.AUDIT_PATH = link
            try:
                with self.assertRaises(MOD.AuditUnavailable):
                    MOD.audit({"op": "test"})
                with open(target, encoding="ascii") as fh:
                    self.assertEqual(fh.read(), "")
            finally:
                MOD.AUDIT_PATH = old

    def test_audit_appends_json_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "sub", "audit.jsonl")
            old = MOD.AUDIT_PATH
            MOD.AUDIT_PATH = path
            try:
                MOD.audit({"op": "list", "outcome": "ok"})
                MOD.audit({"op": "attach", "outcome": "denied"})
                with open(path, encoding="ascii") as fh:
                    lines = fh.read().splitlines()
                self.assertEqual(len(lines), 2)
                import json
                first = json.loads(lines[0])
                self.assertEqual(first["op"], "list")
                self.assertIn("at", first)
            finally:
                MOD.AUDIT_PATH = old


def write_fake_tmux(tmp):
    path = os.path.join(tmp, "fake_tmux.sh")
    with open(path, "w", encoding="ascii") as fh:
        fh.write("#!/bin/sh\nexec cat\n")
    os.chmod(path, 0o755)
    return path


def _run_attach_in_child(argv, tier, r_stdin, w_stdout):
    pid = os.fork()
    if pid == 0:
        os.close(0)
        os.dup2(r_stdin, 0)
        os.close(1)
        os.dup2(w_stdout, 1)

        class FakeStdin:
            def fileno(self):
                return 0

            def isatty(self):
                return False

        class FakeStdout:
            def fileno(self):
                return 1

        sys.stdin = FakeStdin()
        sys.stdout = FakeStdout()
        try:
            MOD.run_attach(argv, tier)
        finally:
            os._exit(0)
    return pid


class PtyRelayTests(unittest.TestCase):
    def test_viewer_discards_client_bytes_even_though_the_child_echoes(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = write_fake_tmux(tmp)
            r_stdin, w_stdin = os.pipe()
            r_stdout, w_stdout = os.pipe()
            pid = _run_attach_in_child([fake], "viewer", r_stdin, w_stdout)
            os.close(r_stdin)
            os.close(w_stdout)
            try:
                time.sleep(0.3)
                os.write(w_stdin, b"SHOULD_NOT_ECHO\n")
                time.sleep(0.5)
                os.close(w_stdin)
                os.set_blocking(r_stdout, False)
                seen = b""
                deadline = time.time() + 2
                while time.time() < deadline:
                    try:
                        chunk = os.read(r_stdout, 4096)
                    except (BlockingIOError, OSError):
                        chunk = b""
                    if chunk:
                        seen += chunk
                    else:
                        time.sleep(0.05)
                self.assertNotIn(b"SHOULD_NOT_ECHO", seen)
            finally:
                os.close(r_stdout)
                os.kill(pid, 9)
                os.waitpid(pid, 0)

    def test_full_attach_relays_stdin_to_pty_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = write_fake_tmux(tmp)
            r_stdin, w_stdin = os.pipe()
            r_stdout, w_stdout = os.pipe()
            pid = _run_attach_in_child([fake], "full-attach", r_stdin, w_stdout)
            os.close(r_stdin)
            os.close(w_stdout)
            try:
                time.sleep(0.3)
                os.write(w_stdin, b"ECHO_ME\n")
                time.sleep(0.5)
                os.close(w_stdin)
                os.set_blocking(r_stdout, False)
                seen = b""
                deadline = time.time() + 2
                while time.time() < deadline:
                    try:
                        chunk = os.read(r_stdout, 4096)
                    except (BlockingIOError, OSError):
                        chunk = b""
                    if chunk:
                        seen += chunk
                        if b"ECHO_ME" in seen:
                            break
                    else:
                        time.sleep(0.05)
                self.assertIn(b"ECHO_ME", seen)
            finally:
                os.close(r_stdout)
                os.kill(pid, 9)
                os.waitpid(pid, 0)


class SessionNameTests(unittest.TestCase):
    def test_new_session_name_matches_entrypoint_shape(self):
        name = MOD.new_session_name("claude")
        self.assertRegex(name, r"^cbox-claude-[0-9a-f]{16}$")
        self.assertTrue(MOD.SESSION_RE.match(name))

    def test_session_re_rejects_path_traversal(self):
        self.assertIsNone(MOD.SESSION_RE.match("../../etc/passwd"))

    def test_session_re_accepts_realistic_name(self):
        self.assertIsNotNone(MOD.SESSION_RE.match("cbox-codex-deadbeef"))


class ScriptHarnessTests(unittest.TestCase):
    def test_pty_round_trip_via_script(self):
        if not os.path.exists("/usr/bin/script"):
            self.skipTest("script(1) not available on this host")
        with tempfile.TemporaryDirectory() as tmp:
            typescript = os.path.join(tmp, "typescript")
            cmd = (
                "script -qec 'printf hello-from-pty' %s > /dev/null" % typescript
            )
            subprocess.run(["/bin/sh", "-c", cmd], timeout=10, check=True)
            with open(typescript, "rb") as fh:
                data = fh.read()
            self.assertIn(b"hello-from-pty", data)


if __name__ == "__main__":
    unittest.main()
