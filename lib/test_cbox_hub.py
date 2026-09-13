import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "lib", "cbox_hub.py")
SPEC = importlib.util.spec_from_file_location("cbox_hub", PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


ISOLATED_CTX = {
    "mode": "isolated",
    "root": "/tmp/proj",
    "eff": "/tmp/eff",
    "conf": "/tmp/eff/cbox.conf",
    "compose_argv": ["docker", "compose", "--project-directory", "/tmp/eff", "-f", "/tmp/eff/docker-compose.yml"],
    "service": "cbox",
    "egress": "off",
}

GLOBAL_CTX = dict(ISOLATED_CTX)
GLOBAL_CTX.update({"mode": "global", "root": "/tmp/proj"})


class StubProbeUnknown(object):
    def container_id(self):
        raise RuntimeError("docker not available in this environment")

    def container_state(self, cid):
        raise RuntimeError("docker not available in this environment")

    def running_engines(self, cid, names):
        raise RuntimeError("docker not available in this environment")


class StubProbeDown(object):
    def container_id(self):
        return None

    def container_state(self, cid):
        return "down"

    def running_engines(self, cid, names):
        return dict((n, "unknown") for n in names)


class StubProbeUp(object):
    def container_id(self):
        return "abc123"

    def container_state(self, cid):
        return "up (since 2026-08-05T10:00:00)"

    def running_engines(self, cid, names):
        return dict((n, "running") for n in names)


class BuildStatusRowsTests(unittest.TestCase):
    def test_probe_error_degrades_to_unknown_never_raises(self):
        rows = MOD.build_status_rows(ISOLATED_CTX, StubProbeUnknown(), ["claude", "codex"])
        by_label = dict(rows)
        self.assertEqual(by_label["container"], "unknown")
        self.assertEqual(by_label["engines"], "claude codex")

    def test_down_state_rendered(self):
        rows = MOD.build_status_rows(ISOLATED_CTX, StubProbeDown(), ["claude", "codex"])
        by_label = dict(rows)
        self.assertEqual(by_label["container"], "down")

    def test_up_state_and_running_engines_rendered(self):
        rows = MOD.build_status_rows(ISOLATED_CTX, StubProbeUp(), ["claude", "codex"])
        by_label = dict(rows)
        self.assertIn("up", by_label["container"])
        self.assertIn("claude(running)", by_label["engines"])
        self.assertIn("codex(running)", by_label["engines"])

    def test_empty_engine_list_renders_placeholder(self):
        rows = MOD.build_status_rows(ISOLATED_CTX, StubProbeDown(), [])
        by_label = dict(rows)
        self.assertEqual(by_label["engines"], "<none>")

    def test_egress_missing_key_degrades_to_unknown(self):
        ctx = dict(ISOLATED_CTX)
        del ctx["egress"]
        rows = MOD.build_status_rows(ctx, StubProbeDown(), [])
        by_label = dict(rows)
        self.assertEqual(by_label["egress"], "unknown")


class BuildScreenTests(unittest.TestCase):
    def test_full_engine_list_isolated_rows(self):
        status_rows = MOD.build_status_rows(ISOLATED_CTX, StubProbeDown(), ["claude", "codex"])
        screen, rows = MOD.build_screen(ISOLATED_CTX, ["claude", "codex"], status_rows)
        self.assertIn("cbox - /tmp/proj   mode: isolated", screen)
        self.assertIn("1) claude", screen)
        self.assertIn("2) codex", screen)
        self.assertNotIn("(ends hub)", screen)
        self.assertEqual(rows, ["engine:claude", "engine:codex", "shell", "logs", "doctor", "settings", "down"])

    def test_empty_engine_list_isolated_rows(self):
        status_rows = MOD.build_status_rows(ISOLATED_CTX, StubProbeDown(), [])
        screen, rows = MOD.build_screen(ISOLATED_CTX, [], status_rows)
        self.assertEqual(rows, ["shell", "logs", "doctor", "settings", "down"])
        self.assertIn("1) shell", screen)

    def test_global_mode_marks_ends_hub(self):
        status_rows = MOD.build_status_rows(GLOBAL_CTX, StubProbeDown(), ["claude"])
        screen, rows = MOD.build_screen(GLOBAL_CTX, ["claude"], status_rows)
        self.assertIn("(ends hub)", screen)
        self.assertIn("shell (ends hub)", screen)

    def test_quit_row_always_present(self):
        status_rows = MOD.build_status_rows(ISOLATED_CTX, StubProbeDown(), [])
        screen, _rows = MOD.build_screen(ISOLATED_CTX, [], status_rows)
        self.assertIn("q) quit", screen)


class ActionArgvTests(unittest.TestCase):
    def test_engine_row_maps_to_run(self):
        self.assertEqual(MOD.action_argv("/x", "/x/cbox", "engine:claude", ISOLATED_CTX), ["/x/cbox", "run", "claude"])

    def test_shell_row_maps_to_shell(self):
        self.assertEqual(MOD.action_argv("/x", "/x/cbox", "shell", ISOLATED_CTX), ["/x/cbox", "shell"])

    def test_logs_row_maps_to_logs(self):
        self.assertEqual(MOD.action_argv("/x", "/x/cbox", "logs", ISOLATED_CTX), ["/x/cbox", "logs"])

    def test_doctor_row_maps_to_doctor(self):
        self.assertEqual(MOD.action_argv("/x", "/x/cbox", "doctor", ISOLATED_CTX), ["/x/cbox", "doctor"])

    def test_down_row_maps_to_down(self):
        self.assertEqual(MOD.action_argv("/x", "/x/cbox", "down", ISOLATED_CTX), ["/x/cbox", "down"])

    def test_settings_row_isolated_adds_local_root(self):
        argv = MOD.action_argv("/x", "/x/cbox", "settings", ISOLATED_CTX)
        self.assertEqual(argv[:2], [MOD.sys.executable, "/x/lib/cbox_settings.py"])
        self.assertEqual(argv[2:], ["/x", "/x/cbox", "--local", "/tmp/proj"])

    def test_settings_row_global_has_no_local_flag(self):
        argv = MOD.action_argv("/x", "/x/cbox", "settings", GLOBAL_CTX)
        self.assertEqual(argv, [MOD.sys.executable, "/x/lib/cbox_settings.py", "/x", "/x/cbox"])

    def test_unknown_row_returns_none(self):
        self.assertIsNone(MOD.action_argv("/x", "/x/cbox", "bogus", ISOLATED_CTX))

    def test_settings_row_isolated_without_root_returns_none(self):
        ctx = dict(ISOLATED_CTX)
        ctx["root"] = ""
        self.assertIsNone(MOD.action_argv("/x", "/x/cbox", "settings", ctx))
        ctx2 = dict(ISOLATED_CTX)
        del ctx2["root"]
        self.assertIsNone(MOD.action_argv("/x", "/x/cbox", "settings", ctx2))


class RunActionDispatchTests(unittest.TestCase):
    def test_engine_action_invokes_subprocess_call_with_exact_argv_no_docker(self):
        calls = []

        def fake_call(argv):
            calls.append(argv)
            return 0

        old = MOD.subprocess.call
        MOD.subprocess.call = fake_call
        try:
            rc = MOD.run_action("/x", "/x/cbox", "engine:claude", ISOLATED_CTX)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [["/x/cbox", "run", "claude"]])

    def test_settings_action_invokes_subprocess_with_settings_script(self):
        calls = []

        def fake_call(argv):
            calls.append(argv)
            return 0

        old = MOD.subprocess.call
        MOD.subprocess.call = fake_call
        try:
            rc = MOD.run_action("/x", "/x/cbox", "settings", ISOLATED_CTX)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], "/x/lib/cbox_settings.py")

    def test_unknown_row_returns_nonzero_without_exec(self):
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv: (_ for _ in ()).throw(AssertionError("must not exec for unknown row"))
        try:
            rc = MOD.run_action("/x", "/x/cbox", "bogus", ISOLATED_CTX)
        finally:
            MOD.subprocess.call = old
        self.assertNotEqual(rc, 0)

    def test_oserror_on_exec_degrades_to_nonzero_not_crash(self):
        def raising_call(argv):
            raise OSError("no such file")

        old = MOD.subprocess.call
        MOD.subprocess.call = raising_call
        try:
            rc = MOD.run_action("/x", "/x/cbox", "shell", ISOLATED_CTX)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 1)


class EnginesFromRegistryTests(unittest.TestCase):
    def test_real_registry_includes_claude_and_codex(self):
        names = MOD.engines_from_registry(ROOT)
        self.assertIn("claude", names)
        self.assertIn("codex", names)

    def test_missing_registry_falls_back_to_claude_codex(self):
        with tempfile.TemporaryDirectory() as tmp:
            names = MOD.engines_from_registry(tmp)
            self.assertEqual(names, ["claude", "codex"])

    def test_malformed_registry_json_falls_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "etc", "engines"))
            with open(os.path.join(tmp, "etc", "engines", "engines.json"), "w", encoding="ascii") as fh:
                fh.write("{not valid json")
            names = MOD.engines_from_registry(tmp)
            self.assertEqual(names, ["claude", "codex"])

    def test_enabled_var_gate_off_excludes_engine(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "etc", "engines"))
            reg = {
                "engines": {
                    "claude": {"enabled_var": None},
                    "hermes": {"enabled_var": "CBOX_HERMES_TEST_FLAG"},
                }
            }
            with open(os.path.join(tmp, "etc", "engines", "engines.json"), "w", encoding="ascii") as fh:
                json.dump(reg, fh)
            old = os.environ.pop("CBOX_HERMES_TEST_FLAG", None)
            try:
                names = MOD.engines_from_registry(tmp)
                self.assertEqual(names, ["claude"])
                os.environ["CBOX_HERMES_TEST_FLAG"] = "on"
                names = MOD.engines_from_registry(tmp)
                self.assertEqual(names, ["claude", "hermes"])
            finally:
                if old is None:
                    os.environ.pop("CBOX_HERMES_TEST_FLAG", None)
                else:
                    os.environ["CBOX_HERMES_TEST_FLAG"] = old


class ContextFromCboxTests(unittest.TestCase):
    def test_nonzero_exit_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = os.path.join(tmp, "fake_cbox")
            with open(fake, "w", encoding="ascii") as fh:
                fh.write("#!/bin/sh\nexit 1\n")
            os.chmod(fake, 0o755)
            self.assertIsNone(MOD.context_from_cbox(tmp, fake))

    def test_malformed_json_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = os.path.join(tmp, "fake_cbox")
            with open(fake, "w", encoding="ascii") as fh:
                fh.write("#!/bin/sh\necho 'not json'\n")
            os.chmod(fake, 0o755)
            self.assertIsNone(MOD.context_from_cbox(tmp, fake))

    def test_missing_binary_returns_none_not_raise(self):
        self.assertIsNone(MOD.context_from_cbox("/tmp", "/does/not/exist/cbox"))

    def test_well_formed_context_parsed(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = os.path.join(tmp, "fake_cbox")
            payload = json.dumps({"mode": "isolated", "root": "/x"})
            with open(fake, "w", encoding="ascii") as fh:
                fh.write("#!/bin/sh\necho '%s'\n" % payload)
            os.chmod(fake, 0o755)
            ctx = MOD.context_from_cbox(tmp, fake)
            self.assertEqual(ctx["mode"], "isolated")


class HubLoopNavigationTests(unittest.TestCase):
    def test_quit_selection_returns_immediately(self):
        calls = []
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv: calls.append(argv) or 0
        try:
            out = io.StringIO()
            rc = MOD.hub_loop(ROOT, "/x/cbox", ISOLATED_CTX, StubProbeDown(), io.StringIO("q\n"), out.write)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [])

    def test_eof_quits_cleanly(self):
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, "/x/cbox", ISOLATED_CTX, StubProbeDown(), io.StringIO(""), out.write)
        self.assertEqual(rc, 0)
        self.assertIn("EOF", out.getvalue())

    def test_invalid_selection_reprompts_without_exec(self):
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv: (_ for _ in ()).throw(AssertionError("must not exec on invalid selection"))
        try:
            out = io.StringIO()
            rc = MOD.hub_loop(ROOT, "/x/cbox", ISOLATED_CTX, StubProbeDown(), io.StringIO("zz\nq\n"), out.write)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 0)
        self.assertIn("unrecognized selection 'zz'", out.getvalue())

    def test_engine_selection_produces_exact_argv_without_docker(self):
        calls = []
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv: calls.append(argv) or 0
        try:
            out = io.StringIO()
            rc = MOD.hub_loop(ROOT, "/x/cbox", ISOLATED_CTX, StubProbeDown(), io.StringIO("1\nq\n"), out.write)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ["/x/cbox", "run"])

    def test_global_mode_engine_selection_ends_hub_loop(self):
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv: 0
        try:
            out = io.StringIO()
            rc = MOD.hub_loop(ROOT, "/x/cbox", GLOBAL_CTX, StubProbeDown(), io.StringIO("1\n"), out.write)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 0)

    def test_out_of_range_selection_reprompts(self):
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, "/x/cbox", ISOLATED_CTX, StubProbeDown(), io.StringIO("999\nq\n"), out.write)
        self.assertEqual(rc, 0)
        self.assertIn("unrecognized selection '999'", out.getvalue())


class MainNonTtyTests(unittest.TestCase):
    def test_main_argument_shortage_returns_1(self):
        self.assertEqual(MOD.main(["cbox_hub.py"]), 1)


class NullProbeTests(unittest.TestCase):
    def test_null_probe_never_touches_docker(self):
        probe = MOD.NullProbe()
        self.assertIsNone(probe.container_id())
        self.assertEqual(probe.container_state(None), "unknown")
        self.assertEqual(probe.running_engines(None, ["claude"]), {"claude": "unknown"})


if __name__ == "__main__":
    unittest.main()
