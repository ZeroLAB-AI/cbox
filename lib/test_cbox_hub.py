import importlib.util
import inspect
import io
import json
import os
import subprocess
import tempfile
import threading
import time
import unicodedata
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib")

import sys
sys.path.insert(0, LIB)

PATH = os.path.join(LIB, "cbox_hub.py")
SPEC = importlib.util.spec_from_file_location("cbox_hub", PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

import cbox_hub_screens as screens
import cbox_hub_ui as ui


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

CBOX_PATH = "/x/cbox"


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


def load_fixture(name):
    path = os.path.join(LIB, "fixtures", "hub", name + ".json")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_golden(name):
    path = os.path.join(LIB, "fixtures", "hub", name + ".txt")
    with open(path, encoding="utf-8") as fh:
        return fh.read()


class GoldenScreenTests(unittest.TestCase):
    def _assert_cols_and_ascii(self, text):
        self._assert_display_cols(text)
        for line in text.splitlines():
            line.encode("ascii")

    def _assert_display_cols(self, text):
        for line in text.splitlines():
            self.assertLessEqual(screens.display_width(line), 80, line)

    def test_main_isolated_matches_golden(self):
        snap = load_fixture("main_isolated")
        text, actions = screens.render_main(snap)
        self.assertEqual(text, load_golden("main_isolated"))
        self._assert_cols_and_ascii(text)

    def test_main_global_matches_golden(self):
        snap = load_fixture("main_global")
        text, actions = screens.render_main(snap)
        self.assertEqual(text, load_golden("main_global"))
        self._assert_cols_and_ascii(text)

    def test_wireguard_matches_golden(self):
        snap = load_fixture("wireguard")
        text, actions = screens.render_wireguard(snap)
        self.assertEqual(text, load_golden("wireguard"))
        self._assert_cols_and_ascii(text)

    def test_all_submenus_stay_in_budget(self):
        snap = {"ctx": GLOBAL_CTX, "cbox_path": CBOX_PATH}
        for name, fn in screens.RENDERERS.items():
            text, _actions = fn(snap)
            self._assert_cols_and_ascii(text)

    def test_hints_screen_stays_in_budget(self):
        snap = load_fixture("main_isolated")
        _text, actions = screens.render_main(snap)
        hints = screens.render_hints(actions)
        self._assert_cols_and_ascii(hints)


class LocalBackendScreenTests(unittest.TestCase):
    def test_main_menu_offers_hyperqwen_and_llm_on_free_keys(self):
        _text, actions = screens.render_main(load_fixture("main_isolated"))
        by_key = dict((a.key, a) for a in actions)
        self.assertEqual(by_key["h"].kind, "submenu")
        self.assertEqual(by_key["h"].submenu, "hyperqwen")
        self.assertEqual(by_key["l"].kind, "submenu")
        self.assertEqual(by_key["l"].submenu, "llm")
        keys = [a.key for a in actions]
        self.assertEqual(len(keys), len(set(keys)), "duplicate main menu keys: %s" % keys)

    def test_hyperqwen_and_llm_screens_are_registered(self):
        self.assertIn("hyperqwen", screens.RENDERERS)
        self.assertIn("llm", screens.RENDERERS)

    def test_submenu_keys_are_unique_per_screen(self):
        for name in ("hyperqwen", "llm", "ollama"):
            keys = [a.key for a in _actions_for(name)]
            self.assertEqual(len(keys), len(set(keys)), "%s has duplicate keys: %s" % (name, keys))

    def test_llm_use_with_model_builds_the_explicit_model_argv(self):
        action = dict((a.key, a) for a in _actions_for("llm"))["m"]
        self.assertEqual(action.argv_builder("hyperqwen qwen3.8-27b"),
                         [CBOX_PATH, "llm", "use", "hyperqwen", "--model", "qwen3.8-27b"])
        self.assertIn("llm use", action.hint)
        self.assertTrue(action.prompt)

    def test_llm_use_with_model_rejects_malformed_input(self):
        action = dict((a.key, a) for a in _actions_for("llm"))["m"]
        for bad in ("", "ollama", "ollama a b", "vllm qwen", "ollama --model", "ollama -x"):
            self.assertIsNone(action.argv_builder(bad), bad)

    def test_backend_screens_never_confirm(self):
        for name in ("hyperqwen", "llm"):
            for a in _actions_for(name):
                self.assertFalse(a.confirm, "%s/%s" % (name, a.key))


class RunningEngineLabelTests(unittest.TestCase):
    def test_running_engine_shows_attach_not_start(self):
        snap = {
            "ctx": ISOLATED_CTX,
            "engine_names": ["claude", "codex"],
            "engine_state": {"claude": "running", "codex": "down"},
            "container_state": "up (since x)",
            "cbox_path": CBOX_PATH,
            "doctor_warnings": None,
        }
        text, _actions = screens.render_main(snap)
        self.assertIn("claude", text)
        claude_line = [l for l in text.splitlines() if "claude" in l][0]
        codex_line = [l for l in text.splitlines() if "codex" in l][0]
        self.assertIn("attach", claude_line)
        self.assertNotIn("start", claude_line)
        self.assertIn("start", codex_line)
        self.assertNotIn("attach", codex_line)

    def test_unknown_engine_state_shows_start(self):
        snap = {
            "ctx": ISOLATED_CTX,
            "engine_names": ["claude"],
            "engine_state": {"claude": "unknown"},
            "container_state": "unknown",
            "cbox_path": CBOX_PATH,
            "doctor_warnings": None,
        }
        text, _actions = screens.render_main(snap)
        self.assertIn("start", text)
        self.assertNotIn("attach", text)


ARGV_TABLE = {
    "main": {
        "1": ["run", ["run", "claude"]],
        "2": ["run", ["run", "codex"]],
        "t": ["run", ["shell"]],
    },
    "sessions": {
        "l": ["run", ["session", "list"]],
        "n": ["run", ["session", "new"]],
        "s": ["builder", ["session", "show", "SID"]],
        "c": ["builder", ["session", "close", "SID"]],
    },
    "network": {
        "s": ["run", ["netaccess", "status"]],
        "a": ["builder", ["netaccess", "allow", "TARGET"]],
        "x": ["builder", ["netaccess", "deny", "TARGET"]],
    },
    "ollama": {
        "s": ["run", ["ollama", "status"]],
        "p": ["run", ["ollama", "ps"]],
        "u": ["run", ["ollama", "up"]],
        "d": ["run", ["ollama", "down"]],
        "l": ["builder", ["ollama", "pull", "MODEL"]],
        "r": ["run", ["ollama", "reconcile"]],
        "g": ["run", ["ollama", "gpu-check"]],
    },
    "hyperqwen": {
        "s": ["run", ["hyperqwen", "status"]],
        "p": ["run", ["hyperqwen", "ps"]],
        "u": ["run", ["hyperqwen", "up"]],
        "d": ["run", ["hyperqwen", "down"]],
        "a": ["run", ["hyperqwen", "prepare"]],
        "r": ["run", ["hyperqwen", "reconcile"]],
        "l": ["run", ["hyperqwen", "logs"]],
        "g": ["run", ["hyperqwen", "gpu-check"]],
    },
    "llm": {
        "s": ["run", ["llm", "status"]],
        "o": ["run", ["llm", "use", "ollama"]],
        "h": ["run", ["llm", "use", "hyperqwen"]],
        "m": ["builder", ["llm", "use", "ollama", "--model", "qwen2.5:7b"]],
    },
    "wireguard": {
        "s": ["run", ["wg", "status"]],
        "u": ["run", ["wg", "up"]],
        "d": ["run", ["wg", "down"]],
        "a": ["builder", ["wg", "server", "add-client", "NAME"]],
        "p": ["builder", ["wg", "server", "add-client", "NAME", "--plain"]],
        "x": ["builder", ["wg", "peer", "rm", "NAME"]],
        "j": ["builder", ["wg", "client", "join", "TOKEN"]],
    },
    "maintenance": {
        "d": ["run", ["down"]],
        "r": ["run", ["restart"]],
        "o": ["run", ["doctor"]],
        "l": ["run", ["logs"]],
        "u": ["run", ["reinstall-bins", "--if-stale"]],
        "y": ["run", ["bins", "status"]],
        "z": ["run", ["bins", "rollback"]],
        "g": ["run", ["images", "list"]],
        "x": ["builder", ["images", "rm", "HASH"]],
        "c": ["run", ["gc"]],
        "k": ["run", ["backup"]],
        "f": ["run", ["net-refresh"]],
        "p": ["run", ["ls"]],
        "t": ["run", ["session-broker", "status"]],
        "h": ["run", ["install-hooks"]],
    },
}

SAMPLE_TEXT_BY_ACTION = {
    ("sessions", "s"): "SID",
    ("sessions", "c"): "SID",
    ("network", "a"): "TARGET",
    ("network", "x"): "TARGET",
    ("ollama", "l"): "MODEL",
    ("llm", "m"): "ollama qwen2.5:7b",
    ("wireguard", "a"): "NAME",
    ("wireguard", "p"): "NAME",
    ("wireguard", "x"): "NAME",
    ("wireguard", "j"): "TOKEN",
    ("maintenance", "x"): "HASH",
}

CONFIRM_KEYS = {
    ("wireguard", "u"),
    ("wireguard", "p"),
    ("wireguard", "x"),
    ("maintenance", "z"),
    ("maintenance", "x"),
    ("maintenance", "c"),
    ("sessions", "c"),
}


def _actions_for(screen_name, engine_state=None):
    if screen_name == "main":
        snap = {
            "ctx": ISOLATED_CTX,
            "engine_names": ["claude", "codex"],
            "engine_state": {"claude": "down", "codex": "down"},
            "container_state": "down",
            "cbox_path": CBOX_PATH,
            "doctor_warnings": None,
        }
        _text, actions = screens.render_main(snap)
    else:
        snap = {
            "ctx": ISOLATED_CTX,
            "cbox_path": CBOX_PATH,
            "engine_state": engine_state or {},
        }
        _text, actions = screens.RENDERERS[screen_name](snap)
    return actions


class ArgvTableTests(unittest.TestCase):
    def test_every_action_matches_the_expected_argv(self):
        for screen_name, table in ARGV_TABLE.items():
            actions = _actions_for(screen_name)
            by_key = dict((a.key, a) for a in actions)
            for key, (kind, expected_tail) in table.items():
                self.assertIn(key, by_key, "%s missing key %s" % (screen_name, key))
                action = by_key[key]
                expected_argv = [CBOX_PATH] + expected_tail
                if kind == "run":
                    self.assertEqual(action.argv, expected_argv,
                                      "%s/%s argv mismatch" % (screen_name, key))
                else:
                    sample = SAMPLE_TEXT_BY_ACTION[(screen_name, key)]
                    got = action.argv_builder(sample)
                    self.assertEqual(got, expected_argv,
                                      "%s/%s built argv mismatch" % (screen_name, key))

    def test_every_screen_has_a_back_action_except_main(self):
        for name in screens.RENDERERS:
            actions = _actions_for(name)
            keys = [a.key for a in actions]
            self.assertIn("b", keys, "%s has no back action" % name)
            back = [a for a in actions if a.key == "b"][0]
            self.assertEqual(back.kind, "back")


class ConfirmationGatingTests(unittest.TestCase):
    def test_only_the_listed_actions_ask_for_confirmation(self):
        for screen_name in list(ARGV_TABLE.keys()) + ["main"]:
            actions = _actions_for(screen_name)
            for a in actions:
                expect_confirm = (screen_name, a.key) in CONFIRM_KEYS
                self.assertEqual(a.confirm, expect_confirm,
                                  "%s/%s confirm=%s expected %s" %
                                  (screen_name, a.key, a.confirm, expect_confirm))

    def test_down_never_confirms_when_no_engine_is_running(self):
        actions = _actions_for("maintenance", engine_state={"claude": "down"})
        down = [a for a in actions if a.key == "d"][0]
        self.assertFalse(down.confirm)
        self.assertIsNone(down.force_token)

    def test_down_requires_force_token_when_an_engine_is_running(self):
        actions = _actions_for("maintenance", engine_state={"claude": "running"})
        down = [a for a in actions if a.key == "d"][0]
        self.assertTrue(down.confirm)
        self.assertEqual(down.force_token, "FORCE")

    def test_confirm_declines_on_no_and_does_not_run(self):
        calls = []
        actions = _actions_for("maintenance")
        rollback = [a for a in actions if a.key == "z"][0]
        keys = ui.LineKeys(io.StringIO("n\n"), io.StringIO())
        stdout = io.StringIO()
        outcome, rc = MOD.run_action(rollback, keys, stdout, ROOT, CBOX_PATH,
                                      ISOLATED_CTX, lambda argv: calls.append(argv) or 0)
        self.assertEqual(outcome, "noop")
        self.assertEqual(calls, [])

    def test_confirm_runs_on_yes(self):
        calls = []
        actions = _actions_for("maintenance")
        rollback = [a for a in actions if a.key == "z"][0]
        keys = ui.LineKeys(io.StringIO("y\n"), io.StringIO())
        stdout = io.StringIO()
        outcome, rc = MOD.run_action(rollback, keys, stdout, ROOT, CBOX_PATH,
                                      ISOLATED_CTX, lambda argv: calls.append(argv) or 0)
        self.assertEqual(outcome, "ran")
        self.assertEqual(calls, [[CBOX_PATH, "bins", "rollback"]])

    def test_force_token_wrong_text_cancels(self):
        calls = []
        actions = _actions_for("maintenance", engine_state={"claude": "running"})
        down = [a for a in actions if a.key == "d"][0]
        keys = ui.LineKeys(io.StringIO("nah\n"), io.StringIO())
        stdout = io.StringIO()
        outcome, rc = MOD.run_action(down, keys, stdout, ROOT, CBOX_PATH,
                                      ISOLATED_CTX, lambda argv: calls.append(argv) or 0)
        self.assertEqual(outcome, "noop")
        self.assertEqual(calls, [])

    def test_force_token_exact_match_runs_with_force_flag(self):
        calls = []
        actions = _actions_for("maintenance", engine_state={"claude": "running"})
        down = [a for a in actions if a.key == "d"][0]
        keys = ui.LineKeys(io.StringIO("FORCE\n"), io.StringIO())
        stdout = io.StringIO()
        outcome, rc = MOD.run_action(down, keys, stdout, ROOT, CBOX_PATH,
                                      ISOLATED_CTX, lambda argv: calls.append(argv) or 0)
        self.assertEqual(outcome, "ran")
        self.assertEqual(calls, [[CBOX_PATH, "down", "--force"]])

    def test_force_token_eof_returns_eof_outcome(self):
        calls = []
        actions = _actions_for("maintenance", engine_state={"claude": "running"})
        down = [a for a in actions if a.key == "d"][0]
        keys = ui.LineKeys(io.StringIO(""), io.StringIO())
        stdout = io.StringIO()
        outcome, rc = MOD.run_action(down, keys, stdout, ROOT, CBOX_PATH,
                                      ISOLATED_CTX, lambda argv: calls.append(argv) or 0)
        self.assertEqual(outcome, "eof")
        self.assertEqual(calls, [])


class RawLineModeSelectionTests(unittest.TestCase):
    def test_plain_forced_env_selects_line_mode(self):
        old = os.environ.get("CBOX_HUB_PLAIN")
        os.environ["CBOX_HUB_PLAIN"] = "1"
        try:
            self.assertFalse(ui.raw_keys_available(io.StringIO(), io.StringIO()))
        finally:
            if old is None:
                os.environ.pop("CBOX_HUB_PLAIN", None)
            else:
                os.environ["CBOX_HUB_PLAIN"] = old

    def test_non_tty_stringio_selects_line_mode(self):
        keys = ui.make_keys(io.StringIO("q\n"), io.StringIO())
        self.assertIsInstance(keys, ui.LineKeys)

    def test_raw_mode_failure_falls_back_to_line_mode(self):
        class FakeTTYNoFileno(object):
            def isatty(self):
                return True

            def fileno(self):
                raise OSError("no real fd in this environment")

        self.assertFalse(ui.raw_keys_available(FakeTTYNoFileno(), FakeTTYNoFileno()))
        keys = ui.make_keys(FakeTTYNoFileno(), FakeTTYNoFileno())
        self.assertIsInstance(keys, ui.LineKeys)

    def test_dumb_term_forces_line_mode(self):
        class FakeTTY(object):
            def isatty(self):
                return True

            def fileno(self):
                return 0

        old = os.environ.get("TERM")
        os.environ["TERM"] = "dumb"
        try:
            self.assertFalse(ui.raw_keys_available(FakeTTY(), FakeTTY()))
        finally:
            if old is None:
                os.environ.pop("TERM", None)
            else:
                os.environ["TERM"] = old

    def test_line_mode_fallback_keeps_line_selection_behavior(self):
        keys = ui.make_keys(io.StringIO("q\n"), io.StringIO())
        output = io.StringIO()
        self.assertIsInstance(keys, ui.LineKeys)
        self.assertEqual(ui.read_selection(keys, output, "default"), "q")


class LineKeysHubLoopTests(unittest.TestCase):
    def test_navigate_into_sessions_list_then_back_then_quit(self):
        calls = []

        def runner(argv):
            calls.append(argv)
            return 0

        out = io.StringIO()
        stdin = io.StringIO("e\nl\nb\nq\n")
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(), stdin,
                           out.write, runner=runner)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [[CBOX_PATH, "session", "list"]])
        self.assertIn("cbox  /tmp/proj  isolated", out.getvalue())

    def test_text_input_action_builds_argv_from_typed_line(self):
        calls = []

        def runner(argv):
            calls.append(argv)
            return 0

        out = io.StringIO()
        stdin = io.StringIO("n\na\nshop_db\nb\nq\n")
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(), stdin,
                           out.write, runner=runner)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [[CBOX_PATH, "netaccess", "allow", "shop_db"]])

    def test_quit_selection_returns_immediately(self):
        calls = []
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(),
                           io.StringIO("q\n"), out.write,
                           runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [])

    def test_eof_quits_cleanly(self):
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(),
                           io.StringIO(""), out.write, runner=lambda argv: 0)
        self.assertEqual(rc, 0)
        self.assertIn("EOF", out.getvalue())

    def test_invalid_selection_reprompts_without_exec(self):
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(),
                           io.StringIO("zz\nq\n"), out.write,
                           runner=lambda argv: (_ for _ in ()).throw(
                               AssertionError("must not exec on invalid selection")))
        self.assertEqual(rc, 0)
        self.assertIn("unrecognized selection 'zz'", out.getvalue())

    def test_engine_selection_produces_exact_argv(self):
        calls = []
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(),
                           io.StringIO("1\nq\n"), out.write,
                           runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [[CBOX_PATH, "run", "claude"]])

    def test_global_mode_engine_selection_ends_hub_loop(self):
        rc = MOD.hub_loop(ROOT, CBOX_PATH, GLOBAL_CTX, StubProbeDown(),
                           io.StringIO("1\n"), io.StringIO().write,
                           runner=lambda argv: 0)
        self.assertEqual(rc, 0)

    def test_global_mode_submenu_action_does_not_end_hub_loop(self):
        calls = []
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, GLOBAL_CTX, StubProbeDown(),
                           io.StringIO("m\nr\nb\nq\n"), out.write,
                           runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [[CBOX_PATH, "restart"]])

    def test_out_of_range_selection_reprompts(self):
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(),
                           io.StringIO("999\nq\n"), out.write, runner=lambda argv: 0)
        self.assertEqual(rc, 0)
        self.assertIn("unrecognized selection '999'", out.getvalue())

    def test_confirm_no_skips_destructive_action(self):
        calls = []
        out = io.StringIO()
        stdin = io.StringIO("m\nz\nn\nb\nq\n")
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(), stdin,
                           out.write, runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [])

    def test_confirm_yes_runs_destructive_action(self):
        calls = []
        out = io.StringIO()
        stdin = io.StringIO("m\nz\ny\nb\nq\n")
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(), stdin,
                           out.write, runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [[CBOX_PATH, "bins", "rollback"]])

    def test_down_runs_without_prompt_when_no_engine_running(self):
        calls = []
        out = io.StringIO()
        stdin = io.StringIO("m\nd\nb\nq\n")
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(), stdin,
                           out.write, runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [[CBOX_PATH, "down"]])

    def test_down_requires_typed_force_when_engine_running(self):
        calls = []
        out = io.StringIO()
        stdin = io.StringIO("m\nd\nFORCE\nb\nq\n")
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeUp(), stdin,
                           out.write, runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [[CBOX_PATH, "down", "--force"]])

    def test_down_cancels_on_wrong_typed_text_when_engine_running(self):
        calls = []
        out = io.StringIO()
        stdin = io.StringIO("m\nd\nno\nb\nq\n")
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeUp(), stdin,
                           out.write, runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [])

    def test_settings_row_invokes_cbox_settings_script(self):
        calls = []
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(),
                           io.StringIO("s\nq\n"), out.write,
                           runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], [MOD.sys.executable,
                                         os.path.join(ROOT, "lib", "cbox_settings.py")])
        self.assertIn("--local", calls[0])
        self.assertIn("/tmp/proj", calls[0])

    def test_settings_row_global_has_no_local_flag(self):
        calls = []
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, GLOBAL_CTX, StubProbeDown(),
                           io.StringIO("s\n"), out.write,
                           runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertNotIn("--local", calls[0])

    def test_hints_row_renders_then_returns_to_main(self):
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(),
                           io.StringIO("?\n\nq\n"), out.write, runner=lambda argv: 0)
        self.assertEqual(rc, 0)
        self.assertIn("command hints", out.getvalue())

    def test_refresh_row_reruns_probe_without_exec(self):
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(),
                           io.StringIO("r\nq\n"), out.write,
                           runner=lambda argv: (_ for _ in ()).throw(
                               AssertionError("refresh must not exec anything")))
        self.assertEqual(rc, 0)

    def test_cancelled_text_input_does_not_run(self):
        calls = []
        out = io.StringIO()
        stdin = io.StringIO("n\na\n\nb\nq\n")
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeDown(), stdin,
                           out.write, runner=lambda argv: calls.append(argv) or 0)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [])


class BuildStatusTests(unittest.TestCase):
    def test_probe_error_degrades_to_unknown_never_raises(self):
        status = MOD.gather_status(StubProbeUnknown(), ["claude", "codex"], budget=1.0)
        self.assertEqual(status["container_state"], "unknown")
        self.assertEqual(status["engine_state"], {"claude": "unknown", "codex": "unknown"})

    def test_down_state_rendered(self):
        status = MOD.gather_status(StubProbeDown(), ["claude"], budget=1.0)
        self.assertEqual(status["container_state"], "down")

    def test_up_state_and_running_engines_rendered(self):
        status = MOD.gather_status(StubProbeUp(), ["claude", "codex"], budget=1.0)
        self.assertIn("up", status["container_state"])
        self.assertEqual(status["engine_state"]["claude"], "running")
        self.assertEqual(status["engine_state"]["codex"], "running")

    def test_slow_probe_yields_ellipsis_within_budget(self):
        class SlowProbe(object):
            def __init__(self):
                self.release = threading.Event()

            def container_id(self):
                self.release.wait()
                return None

            def container_state(self, cid):
                return "down"

            def running_engines(self, cid, names):
                return dict((n, "unknown") for n in names)

        import time
        started = time.time()
        probe = SlowProbe()
        status = MOD.gather_status(probe, ["claude"], budget=0.05)
        elapsed = time.time() - started
        self.assertLess(elapsed, 1.0)
        self.assertEqual(status["container_state"], "...")
        probe.release.set()
        probe._hub_probe_state["thread"].join(0.1)


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


class ProfileContextTests(unittest.TestCase):
    def _snap(self, **extra):
        snap = load_fixture("main_isolated")
        snap["ctx"] = dict(snap["ctx"], **extra)
        return snap

    def test_header_names_a_non_default_profile(self):
        text, _actions = screens.render_main(self._snap(profile="work"))
        self.assertIn("  profile work", text.splitlines()[0])

    def test_header_stays_unchanged_for_the_default_profile(self):
        base, _actions = screens.render_main(load_fixture("main_isolated"))
        text, _actions = screens.render_main(self._snap(profile="default", profile_error=""))
        self.assertEqual(text, base)
        self.assertNotIn("profile", text.splitlines()[0])

    def test_header_flags_an_unresolvable_profile(self):
        text, _actions = screens.render_main(self._snap(profile="default", profile_error="the configured profile cannot be resolved"))
        self.assertIn("  profile ?", text.splitlines()[0])

    def test_probe_asks_the_profile_compose_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "argv.log")
            fake = os.path.join(tmp, "fake_docker")
            with open(fake, "w", encoding="ascii") as fh:
                fh.write("#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + log + "\necho cid-profile\n")
            os.chmod(fake, 0o755)
            eff = os.path.join(tmp, "eff", "profiles", "work")
            ctx = {"mode": "isolated", "service": "cbox",
                   "compose_argv": [fake, "compose", "--project-directory", eff, "-f", eff + "/docker-compose.yml"]}
            self.assertEqual(MOD.Probe(ctx).container_id(), "cid-profile")
            with open(log, encoding="ascii") as fh:
                seen = fh.read()
            self.assertIn("--project-directory %s -f %s/docker-compose.yml ps -q cbox" % (eff, eff), seen)


class CliUsageTests(unittest.TestCase):
    def test_missing_binary_falls_back_to_static_usage(self):
        text = MOD.cli_usage("/does/not/exist/cbox")
        self.assertIn("usage:", text)

    def test_real_dispatcher_usage_is_relayed_verbatim(self):
        fake = None
        with tempfile.TemporaryDirectory() as tmp:
            fake = os.path.join(tmp, "fake_cbox")
            with open(fake, "w", encoding="ascii") as fh:
                fh.write("#!/bin/sh\necho 'usage: fake {run|shell}'\nexit 1\n")
            os.chmod(fake, 0o755)
            text = MOD.cli_usage(fake)
            self.assertIn("usage: fake {run|shell}", text)


class MainNonTtyTests(unittest.TestCase):
    def test_main_argument_shortage_returns_1(self):
        self.assertEqual(MOD.main(["cbox_hub.py"]), 1)

    def test_non_tty_stdin_prints_usage_and_returns_1(self):
        class NonTTY(object):
            def isatty(self):
                return False

            def write(self, text):
                pass

        out = NonTTY()
        rc = MOD.main(["cbox_hub.py", ROOT, "/does/not/exist/cbox"], stdin=NonTTY(), stdout=out)
        self.assertEqual(rc, 1)

    def test_non_tty_stdout_prints_usage_and_returns_1(self):
        class TTYStdin(object):
            def isatty(self):
                return True

        class NonTTYStdout(object):
            def isatty(self):
                return False

            def write(self, text):
                pass

        rc = MOD.main(["cbox_hub.py", ROOT, "/does/not/exist/cbox"],
                       stdin=TTYStdin(), stdout=NonTTYStdout())
        self.assertEqual(rc, 1)


class NullProbeTests(unittest.TestCase):
    def test_null_probe_never_touches_docker(self):
        probe = MOD.NullProbe()
        self.assertIsNone(probe.container_id())
        self.assertEqual(probe.container_state(None), "unknown")
        self.assertEqual(probe.running_engines(None, ["claude"]), {"claude": "unknown"})


class SingleInFlightProbeTests(unittest.TestCase):
    def test_refresh_during_slow_probe_starts_only_one_probe_thread(self):
        class BlockingProbe(object):
            def __init__(self):
                self.release = threading.Event()
                self.lock = threading.Lock()
                self.container_id_calls = 0

            def _bump(self):
                with self.lock:
                    self.container_id_calls += 1

            def container_id(self):
                self._bump()
                self.release.wait(5)
                return None

            def container_state(self, cid):
                return "down"

            def running_engines(self, cid, names):
                return dict((n, "down") for n in names)

        probe = BlockingProbe()
        s1 = MOD.gather_status(probe, ["claude", "codex"], budget=0.05)
        first_thread = probe._hub_probe_state["thread"]
        self.assertEqual(s1["container_state"], "...")
        self.assertEqual(s1["engine_state"], {"claude": "...", "codex": "..."})
        self.assertTrue(first_thread.is_alive())
        s2 = MOD.gather_status(probe, ["claude", "codex"], budget=0.05)
        s3 = MOD.gather_status(probe, ["claude", "codex"], budget=0.05)
        self.assertIs(probe._hub_probe_state["thread"], first_thread)
        with probe.lock:
            self.assertEqual(probe.container_id_calls, 1)
        self.assertEqual(s2["container_state"], "...")
        self.assertEqual(s2["engine_state"], {"claude": "...", "codex": "..."})
        self.assertEqual(s3["container_state"], "...")
        probe.release.set()
        first_thread.join(5)
        self.assertFalse(first_thread.is_alive(), "probe thread did not stop after release")
        with probe.lock:
            self.assertEqual(probe.container_id_calls, 1)

    def test_refresh_after_probe_finished_starts_a_fresh_probe(self):
        class FastProbe(object):
            def __init__(self):
                self.lock = threading.Lock()
                self.calls = 0

            def container_id(self):
                with self.lock:
                    self.calls += 1
                return None

            def container_state(self, cid):
                return "down"

            def running_engines(self, cid, names):
                return dict((n, "down") for n in names)

        probe = FastProbe()
        s1 = MOD.gather_status(probe, ["claude"], budget=1.0)
        s1_thread = probe._hub_probe_state["thread"]
        self.assertEqual(s1["container_state"], "down")
        s1_thread.join(5)
        self.assertFalse(s1_thread.is_alive())
        s2 = MOD.gather_status(probe, ["claude"], budget=1.0)
        s2_thread = probe._hub_probe_state["thread"]
        self.assertIsNot(s2_thread, s1_thread)
        s2_thread.join(5)
        self.assertFalse(s2_thread.is_alive())
        with probe.lock:
            self.assertEqual(probe.calls, 2)
        self.assertEqual(s2["container_state"], "down")

    def test_repeated_slow_refresh_without_prior_snapshot_shows_ellipsis(self):
        class OneShotSlowProbe(object):
            def __init__(self):
                self.release = threading.Event()
                self.counter = 0
                self.lock = threading.Lock()

            def container_id(self):
                with self.lock:
                    self.counter += 1
                    n = self.counter
                if n == 1:
                    self.release.wait(5)
                    return None
                raise AssertionError(
                    "a second probe thread must not start while the first is alive")

            def container_state(self, cid):
                return "up (since 2026-09-25T00:00:00)"

            def running_engines(self, cid, names):
                return dict((n, "running") for n in names)

        probe = OneShotSlowProbe()
        s1 = MOD.gather_status(probe, ["claude"], budget=0.05)
        t1 = probe._hub_probe_state["thread"]
        self.assertEqual(s1["container_state"], "...")
        self.assertEqual(s1["engine_state"], {"claude": "..."})
        s2 = MOD.gather_status(probe, ["claude"], budget=0.05)
        self.assertIs(probe._hub_probe_state["thread"], t1)
        self.assertEqual(s2["container_state"], "...")
        self.assertEqual(s2["engine_state"], {"claude": "..."})
        probe.release.set()
        t1.join(5)
        self.assertFalse(t1.is_alive(), "probe thread did not stop after release")
        time_start = time.time()
        s3 = MOD.gather_status(probe, ["claude"], budget=1.0)
        t2 = probe._hub_probe_state["thread"]
        self.assertIsNot(t2, t1)
        t2.join(5)
        self.assertFalse(t2.is_alive())
        self.assertLessEqual(time.time() - time_start, 1.0)
        self.assertIn("up", s3["container_state"])
        self.assertEqual(s3["engine_state"]["claude"], "running")

    def test_slow_probe_with_prior_snapshot_reuses_last_snapshot(self):
        class WarmProbe(object):
            def __init__(self):
                self.block = threading.Event()
                self.lock = threading.Lock()
                self.started = 0

            def container_id(self):
                with self.lock:
                    self.started += 1
                return None

            def container_state(self, cid):
                return "down"

            def running_engines(self, cid, names):
                return dict((n, "down") for n in names)

        probe = WarmProbe()
        s1 = MOD.gather_status(probe, ["claude"], budget=1.0)
        self.assertEqual(s1["container_state"], "down")
        t1 = probe._hub_probe_state["thread"]
        t1.join(5)
        self.assertFalse(t1.is_alive())
        self.assertIsNotNone(probe._hub_probe_state["last"])
        s2 = MOD.gather_status(probe, ["claude"], budget=1.0)
        t2 = probe._hub_probe_state["thread"]
        self.assertIsNot(t2, t1)
        self.assertEqual(s2["container_state"], "down")
        t2.join(5)
        self.assertFalse(t2.is_alive())
        with probe.lock:
            self.assertEqual(probe.started, 2)


class RawConfirmDrainTests(unittest.TestCase):
    class FakeRawInput(object):
        def __init__(self, pending=b""):
            self.pending = pending
            self.pos = 0

        def isatty(self):
            return True

        def fileno(self):
            return 0

        def peek_read(self):
            if self.pos >= len(self.pending):
                return b""
            return self.pending[self.pos:self.pos + 1]

        def advance(self, n):
            self.pos += n

        def remaining(self):
            return self.pending[self.pos:]

    class _ReadGuard(object):
        def __init__(self, fake):
            import select as _select_module
            self.select_module = _select_module
            self.fake = fake
            self.saved_select = None
            self.saved_read = None
            self.saved_tcgetattr = None
            self.saved_tcsetattr = None
            self.saved_setraw = None

        def __enter__(self):
            self.saved_select = self.select_module.select
            self.saved_read = ui.os.read
            import termios
            import tty
            self.termios_module = termios
            self.tty_module = tty
            self.saved_tcgetattr = termios.tcgetattr
            self.saved_tcsetattr = termios.tcsetattr
            self.saved_setraw = tty.setraw
            self.select_module.select = self._fake_select
            ui.os.read = self._fake_read
            termios.tcgetattr = lambda _fd: []
            termios.tcsetattr = lambda _fd, _when, _attrs: None
            tty.setraw = lambda _fd, _when: None
            return self

        def __exit__(self, *exc):
            self.select_module.select = self.saved_select
            ui.os.read = self.saved_read
            self.termios_module.tcgetattr = self.saved_tcgetattr
            self.termios_module.tcsetattr = self.saved_tcsetattr
            self.tty_module.setraw = self.saved_setraw
            return False

        def _fake_select(self, rlist, _wlist, _xlist, _timeout):
            if self.fake.pos < len(self.fake.pending):
                return ([0], [], [])
            return ([], [], [])

        def _fake_read(self, fd, size):
            one = self.fake.peek_read()
            self.fake.advance(len(one))
            return one

    def _confirm_and_next_key(self, pending):
        fake = self.FakeRawInput(pending)
        keys = ui.RawKeys(fake, io.StringIO())
        out = io.StringIO()
        with self._ReadGuard(fake):
            answer = ui.confirm(keys, out, "do it")
            next_key = ui.read_selection(keys, out, "default")
        return answer, next_key, fake, out, keys

    def test_pending_cr_after_y_is_drained_and_not_consumed_as_default(self):
        answer, next_key, fake, _out, _keys = self._confirm_and_next_key(b"y\r")
        self.assertIs(answer, True)
        self.assertIsNone(next_key)
        self.assertEqual(fake.pending, b"")

    def test_pending_lf_after_y_is_drained_and_not_consumed_as_default(self):
        answer, next_key, fake, _out, _keys = self._confirm_and_next_key(b"y\n")
        self.assertIs(answer, True)
        self.assertIsNone(next_key)
        self.assertEqual(fake.pending, b"")

    def test_pending_cr_after_n_is_drained_too(self):
        answer, next_key, fake, _out, _keys = self._confirm_and_next_key(b"n\r")
        self.assertIs(answer, False)
        self.assertIsNone(next_key)
        self.assertEqual(fake.pending, b"")

    def test_drain_stops_at_first_non_newline_key(self):
        _answer, next_key, fake, _out, _keys = self._confirm_and_next_key(b"y\r\nx")
        self.assertEqual(next_key, "x")
        self.assertEqual(fake.remaining(), b"")

    def test_multiple_crlf_run_is_drained(self):
        answer, next_key, fake, _out, _keys = self._confirm_and_next_key(b"y\r\r\n")
        self.assertIs(answer, True)
        self.assertIsNone(next_key)
        self.assertEqual(fake.pending, b"")

    def test_read_ahead_is_consumed_before_fd_bytes_in_order(self):
        fake = self.FakeRawInput(b"ef")
        keys = ui.RawKeys(fake, io.StringIO())
        keys.push_back(b"ab")
        keys.push_back(b"cd")
        with self._ReadGuard(fake):
            values = [keys.read_key() for _ in range(6)]
        self.assertEqual(values, list("abcdef"))

    def test_escape_sequence_iteration_cap_preserves_last_byte(self):
        fake = self.FakeRawInput(b"[" + b"1" * 16 + b"A")
        keys = ui.RawKeys(fake, io.StringIO())
        keys.push_back(b"\x1b")
        with self._ReadGuard(fake):
            self.assertEqual(keys.read_key(), "\x1b[" + "1" * 15)
            self.assertEqual(keys.read_key(), "1")
            self.assertEqual(keys.read_key(), "A")

    def test_escape_sequence_split_between_buffer_and_fd_is_one_key(self):
        fake = self.FakeRawInput(b"[A")
        keys = ui.RawKeys(fake, io.StringIO())
        keys.push_back(b"\x1b")
        with self._ReadGuard(fake):
            self.assertEqual(keys.read_key(), "\x1b[A")
        self.assertEqual(fake.remaining(), b"")

    def test_escape_selection_uses_a_readable_label(self):
        fake = self.FakeRawInput(b"[A")
        keys = ui.RawKeys(fake, io.StringIO())
        keys.push_back(b"\x1b")
        out = io.StringIO()
        with self._ReadGuard(fake):
            self.assertEqual(ui.read_selection(keys, out, "default"), "escape")
        self.assertNotIn("<escape sequence>", out.getvalue())

    def test_utf8_character_split_between_buffer_and_fd_is_one_key(self):
        fake = self.FakeRawInput(b"\xb8\xad")
        keys = ui.RawKeys(fake, io.StringIO())
        keys.push_back(b"\xe4")
        with self._ReadGuard(fake):
            self.assertEqual(keys.read_key(), "\u4e2d")
        self.assertEqual(fake.remaining(), b"")

    def test_raw_keys_module_does_not_reference_tiocsti(self):
        self.assertNotIn("TIOCSTI", inspect.getsource(ui))


class DisplayWidthRowTests(unittest.TestCase):
    WIDE = "\u4e2d"

    def test_cjk_char_counts_as_two_columns(self):
        self.assertEqual(screens.display_width(self.WIDE + "a"), 3)
        self.assertEqual(screens.display_width("a" * 5), 5)

    def test_row_truncates_by_display_width_to_80(self):
        out = screens._row("a" * 100)
        self.assertEqual(out, "a" * 77 + "...")
        self.assertEqual(screens.display_width(out), 80)
        wide = screens._row(self.WIDE * 41)
        self.assertTrue(wide.endswith("..."))
        self.assertLessEqual(screens.display_width(wide), 80)
        mixed = screens._row("a" * 79 + self.WIDE)
        self.assertLessEqual(screens.display_width(mixed), 80)
        self.assertTrue(mixed.endswith("..."))

    def test_row_keeps_text_at_or_below_80_unchanged(self):
        exact = self.WIDE * 40
        self.assertEqual(screens.display_width(exact), 80)
        self.assertEqual(screens._row(exact), exact)
        nearly = self.WIDE * 39 + "a"
        self.assertEqual(screens.display_width(nearly), 79)
        self.assertEqual(screens._row(nearly), nearly)

    def test_row_does_not_split_a_cjk_char_at_the_boundary(self):
        out = screens._row(self.WIDE * 50 + "a")
        self.assertTrue(out.endswith("..."))
        self.assertLessEqual(screens.display_width(out), 80)
        trimmed = out[:-3]
        for ch in trimmed:
            if unicodedata.east_asian_width(ch) in ("W", "F"):
                self.assertLessEqual(screens.display_width(trimmed), 80 - 1)
                break


class CJKRootRenderTests(unittest.TestCase):
    def assert_in_cols(self, text):
        for line in text.splitlines():
            self.assertLessEqual(screens.display_width(line), 80, line)

    def test_cjk_root_of_50_chars_renders_every_line_within_80_columns(self):
        ctx = dict(ISOLATED_CTX)
        cjk_root = "\u6d4b" * 50
        ctx["root"] = cjk_root
        snap = {
            "ctx": ctx,
            "engine_names": ["claude", "codex"],
            "engine_state": {"claude": "running", "codex": "down"},
            "container_state": "up (since 2026-09-25T00:00:00)",
            "cbox_path": CBOX_PATH,
            "doctor_warnings": 2,
        }
        text, _actions = screens.render_main(snap)
        self.assert_in_cols(text)
        first_line = text.splitlines()[0]
        self.assertTrue(first_line.endswith("..."))
        self.assertLessEqual(screens.display_width(first_line), 80)

    def test_cjk_root_in_submenu_header_within_80_columns(self):
        ctx = dict(GLOBAL_CTX)
        cjk_root = "\u4e91" * 40
        ctx["root"] = cjk_root
        snap = {"ctx": ctx, "cbox_path": CBOX_PATH, "engine_state": {}}
        for name, fn in screens.RENDERERS.items():
            text, _actions = fn(snap)
            self.assert_in_cols(text)
            self.assert_in_cols(screens.render_hints(_actions))

    def test_cjk_engine_and_hint_columns_align_by_display_width(self):
        snap = {
            "ctx": ISOLATED_CTX,
            "engine_names": ["\u4e2d"],
            "engine_state": {"\u4e2d": "down"},
            "cbox_path": "\u4e2d" * 60,
        }
        text, actions = screens.render_main(snap)
        row = next(line for line in text.splitlines() if "start" in line)
        self.assertEqual(screens.display_width(row[:row.index("start")]), 13)
        self.assertEqual(screens.display_width(row[:row.index(" e sessions")]), 30)
        footer = text.splitlines()[-1]
        self.assertEqual(screens.display_width(footer), 80)
        hints = screens.render_hints(actions + [
            ui.Action("z", "\u4e2d", hint="zzzz")
        ])
        hint_row = next(line for line in hints.splitlines() if "zzzz" in line)
        self.assertEqual(screens.display_width(hint_row[:hint_row.index("zzzz")]), 20)


def _fake_docker(tmp, body):
    path = os.path.join(tmp, "docker")
    with open(path, "w", encoding="ascii") as fh:
        fh.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)
    return path


class _PathShim(object):
    def __init__(self, directory):
        self.directory = directory

    def __enter__(self):
        self.saved = os.environ.get("PATH", "")
        os.environ["PATH"] = self.directory + os.pathsep + self.saved
        return self

    def __exit__(self, *exc):
        os.environ["PATH"] = self.saved


class SingleExecProbeTests(unittest.TestCase):
    def _probe(self, names=("claude", "codex", "hermes")):
        ctx = {"compose_argv": ["docker", "compose"], "service": "cbox"}
        return MOD.Probe(ctx, ROOT), list(names)

    def test_one_exec_covers_every_engine(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "calls.log")
            args = os.path.join(tmp, "args.log")
            _fake_docker(tmp, 'echo CALL >> ' + log + '\n'
                         'printf "%s\\n" "$@" > ' + args + '\n'
                         'case "$1" in exec) printf "claude\\n/opt/hermes/bin/hermes\\n";; esac\n')
            probe, names = self._probe()
            with _PathShim(tmp):
                result = probe.running_engines("cid9", names)
            self.assertEqual(result, {"claude": "running", "codex": "down", "hermes": "running"})
            with open(log, encoding="ascii") as fh:
                self.assertEqual(fh.read().splitlines(), ["CALL"])
            with open(args, encoding="ascii") as fh:
                seen = fh.read().splitlines()
            self.assertEqual(seen[:4], ["exec", "cid9", "sh", "-c"])
            self.assertEqual(seen[-4:], ["sh", "/opt/hermes/bin/hermes", "claude", "codex"])

    def test_scan_failure_marks_all_down_and_missing_docker_marks_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            _fake_docker(tmp, "exit 125\n")
            probe, names = self._probe(("claude", "codex"))
            with _PathShim(tmp):
                self.assertEqual(probe.running_engines("cid9", names), {"claude": "down", "codex": "down"})
        with tempfile.TemporaryDirectory() as empty:
            probe, names = self._probe(("claude", "codex"))
            saved = os.environ["PATH"]
            os.environ["PATH"] = empty
            try:
                self.assertEqual(probe.running_engines("cid9", names), {"claude": "unknown", "codex": "unknown"})
            finally:
                os.environ["PATH"] = saved

    def test_no_container_is_unknown_without_any_exec(self):
        probe, names = self._probe(("claude",))
        self.assertEqual(probe.running_engines(None, names), {"claude": "unknown"})

    def test_parse_scan_output(self):
        argv1s = {"claude": "claude", "codex": "codex", "hermes": "/opt/hermes/bin/hermes"}
        text = "claude\nclaude\n/opt/hermes/bin/hermes\n\n"
        self.assertEqual(MOD.parse_scan_output(text, argv1s),
                         {"claude": "running", "codex": "down", "hermes": "running"})
        self.assertEqual(MOD.parse_scan_output("", argv1s),
                         {"claude": "down", "codex": "down", "hermes": "down"})

    @unittest.skipUnless(os.path.isdir("/proc/self"), "needs a Linux proc filesystem")
    def test_scan_script_matches_entrypoint_argv1_and_plain_argv0(self):
        sleeper = None
        try:
            sleeper = subprocess.Popen(["/x/entrypoint.sh", "31"], executable="/bin/sleep")
            time.sleep(0.2)
            out = subprocess.run(["sh", "-c", MOD.SCAN_SCRIPT, "sh", "31", "32", "/x/entrypoint.sh"],
                                 stdout=subprocess.PIPE, timeout=15)
            found = set(out.stdout.decode().split())
            self.assertIn("31", found)
            self.assertNotIn("32", found)
            self.assertEqual(out.returncode, 0)
        finally:
            if sleeper is not None:
                sleeper.kill()
                sleeper.wait()


class ConcurrentProbeTests(unittest.TestCase):
    def test_inspect_and_exec_run_concurrently(self):
        barrier = threading.Barrier(2, timeout=3)

        class Probe(object):
            def container_id(self):
                return "cid"

            def container_state(self, cid):
                barrier.wait()
                return "up (since 2026-10-07T10:00:00)"

            def running_engines(self, cid, names):
                barrier.wait()
                return dict((n, "running") for n in names)

        status = MOD.gather_status(Probe(), ["claude", "codex"], budget=5.0)
        self.assertEqual(status["container_state"], "up (since 2026-10-07T10:00:00)")
        self.assertEqual(status["engine_state"], {"claude": "running", "codex": "running"})


class StatusCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.tmp.name, "hub-cache")
        self.now = [1000.0]
        self.cache = MOD.StatusCache(self.dir, "scopea", clock=lambda: self.now[0])
        self.snap = {"container_state": "up (since 2026-10-07T10:00:00)",
                     "engine_state": {"claude": "running", "codex": "down"}}

    def tearDown(self):
        self.tmp.cleanup()

    def test_roundtrip_is_private_and_atomic(self):
        self.assertTrue(self.cache.store(self.snap))
        names = sorted(os.listdir(self.dir))
        self.assertEqual(names, ["status-scopea.json"])
        self.assertEqual(os.stat(os.path.join(self.dir, names[0])).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.dir).st_mode & 0o777, 0o700)
        self.now[0] = 1042.0
        loaded = self.cache.load(["claude", "codex"])
        self.assertEqual(loaded["container_state"], self.snap["container_state"])
        self.assertEqual(loaded["engine_state"], self.snap["engine_state"])
        self.assertTrue(loaded["from_cache"])
        self.assertAlmostEqual(loaded["cached_age"], 42.0)

    def test_store_replaces_and_leaves_no_temp_files(self):
        self.cache.store(self.snap)
        newer = {"container_state": "down", "engine_state": {"claude": "down", "codex": "down"}}
        self.cache.store(newer)
        self.assertEqual(sorted(os.listdir(self.dir)), ["status-scopea.json"])
        self.assertEqual(self.cache.load(["claude", "codex"])["container_state"], "down")

    def test_expiry(self):
        self.cache.store(self.snap)
        self.now[0] = 1000.0 + MOD.CACHE_MAX_AGE_SECONDS
        self.assertIsNotNone(self.cache.load(["claude", "codex"]))
        self.now[0] = 1000.0 + MOD.CACHE_MAX_AGE_SECONDS + 1
        self.assertIsNone(self.cache.load(["claude", "codex"]))

    def test_future_timestamp_is_ignored(self):
        self.cache.store(self.snap)
        self.now[0] = 900.0
        self.assertIsNone(self.cache.load(["claude", "codex"]))

    def test_scope_mismatch_is_ignored(self):
        self.cache.store(self.snap)
        other = MOD.StatusCache(self.dir, "scopeb", clock=lambda: self.now[0])
        self.assertIsNone(other.load(["claude", "codex"]))
        os.rename(os.path.join(self.dir, "status-scopea.json"), os.path.join(self.dir, "status-scopeb.json"))
        self.assertIsNone(other.load(["claude", "codex"]))

    def test_scope_key_follows_compose_argv_and_service(self):
        a = MOD.cache_scope({"compose_argv": ["docker", "compose", "-f", "/a"], "service": "cbox"})
        b = MOD.cache_scope({"compose_argv": ["docker", "compose", "-f", "/b"], "service": "cbox"})
        c = MOD.cache_scope({"compose_argv": ["docker", "compose", "-f", "/a"], "service": "other"})
        self.assertEqual(len(set([a, b, c])), 3)
        self.assertEqual(a, MOD.cache_scope({"compose_argv": ["docker", "compose", "-f", "/a"], "service": "cbox"}))

    def test_engine_set_mismatch_is_ignored(self):
        self.cache.store(self.snap)
        self.assertIsNone(self.cache.load(["claude", "codex", "hermes"]))
        self.assertIsNone(self.cache.load(["claude"]))

    def test_corrupt_or_hostile_content_is_ignored(self):
        self.cache.store(self.snap)
        path = os.path.join(self.dir, "status-scopea.json")
        for body in ("not json", "[]", json.dumps({"v": 2}),
                     json.dumps({"v": 1, "scope": "scopea", "ts": 1000.0,
                                 "container_state": "up\x1b[2J", "engine_state": {"claude": "running", "codex": "down"}}),
                     json.dumps({"v": 1, "scope": "scopea", "ts": 1000.0,
                                 "container_state": "unknown", "engine_state": {"claude": "running", "codex": "down"}}),
                     json.dumps({"v": 1, "scope": "scopea", "ts": 1000.0,
                                 "container_state": "down", "engine_state": {"claude": "...", "codex": "down"}}),
                     "x" * (MOD.CACHE_MAX_BYTES + 10)):
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            os.chmod(path, 0o600)
            self.assertIsNone(self.cache.load(["claude", "codex"]), body[:40])

    def test_loose_file_mode_is_refused(self):
        self.cache.store(self.snap)
        os.chmod(os.path.join(self.dir, "status-scopea.json"), 0o644)
        self.assertIsNone(self.cache.load(["claude", "codex"]))

    def test_symlinked_cache_file_is_refused(self):
        self.cache.store(self.snap)
        real = os.path.join(self.tmp.name, "elsewhere.json")
        path = os.path.join(self.dir, "status-scopea.json")
        os.rename(path, real)
        os.symlink(real, path)
        self.assertIsNone(self.cache.load(["claude", "codex"]))

    def test_symlinked_cache_dir_is_refused_for_load_and_store(self):
        self.cache.store(self.snap)
        real = os.path.join(self.tmp.name, "real-dir")
        os.rename(self.dir, real)
        os.symlink(real, self.dir)
        self.assertIsNone(self.cache.load(["claude", "codex"]))
        before = sorted(os.listdir(real))
        self.assertFalse(self.cache.store(self.snap))
        self.assertEqual(sorted(os.listdir(real)), before)

    def test_store_never_writes_through_a_planted_symlink_target(self):
        self.cache.store(self.snap)
        victim = os.path.join(self.tmp.name, "victim.txt")
        with open(victim, "w", encoding="ascii") as fh:
            fh.write("keep")
        path = os.path.join(self.dir, "status-scopea.json")
        os.unlink(path)
        os.symlink(victim, path)
        self.cache.store(self.snap)
        with open(victim, encoding="ascii") as fh:
            self.assertEqual(fh.read(), "keep")
        self.assertFalse(os.path.islink(path))
        self.assertIsNotNone(self.cache.load(["claude", "codex"]))

    def test_group_writable_dir_is_refused(self):
        self.cache.store(self.snap)
        os.chmod(self.dir, 0o770)
        self.assertIsNone(self.cache.load(["claude", "codex"]))
        self.assertFalse(self.cache.store(self.snap))

    def test_missing_dir_loads_none_without_creating_it(self):
        self.assertIsNone(self.cache.load(["claude", "codex"]))
        self.assertFalse(os.path.exists(self.dir))

    def test_unwritable_location_never_raises(self):
        blocker = os.path.join(self.tmp.name, "blocker")
        with open(blocker, "w", encoding="ascii") as fh:
            fh.write("x")
        bad = MOD.StatusCache(os.path.join(blocker, "sub"), "scopea")
        self.assertFalse(bad.store(self.snap))
        self.assertIsNone(bad.load(["claude", "codex"]))

    def test_age_formatting(self):
        self.assertEqual(MOD.format_age(0.4), "0s")
        self.assertEqual(MOD.format_age(59.9), "59s")
        self.assertEqual(MOD.format_age(61), "1m")
        self.assertEqual(MOD.format_age(599), "9m")


class CachedStatusFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = MOD.StatusCache(os.path.join(self.tmp.name, "c"), "s")
        self.cache.store({"container_state": "up (since 2026-10-07T09:00:00)",
                          "engine_state": {"claude": "running"}})
        self.registry_cache = MOD.StatusCache(os.path.join(self.tmp.name, "r"), "s")
        self.registry_cache.store({
            "container_state": "up (since 2026-10-07T09:00:00)",
            "engine_state": dict((n, "running") for n in MOD.engines_from_registry(ROOT))})

    def tearDown(self):
        self.tmp.cleanup()

    def _gated_probe(self):
        class Gated(object):
            def __init__(self):
                self.release = threading.Event()
                self.calls = 0

            def container_id(self):
                self.calls += 1
                self.release.wait(5)
                return "cid"

            def container_state(self, cid):
                return "up (since 2026-10-07T10:00:00)"

            def running_engines(self, cid, names):
                return dict((n, "down") for n in names)

        return Gated()

    def test_cached_status_is_returned_without_waiting_for_the_probe(self):
        probe = self._gated_probe()
        started = time.time()
        status = MOD.initial_status(probe, ["claude"], self.cache, budget=5.0)
        self.assertLess(time.time() - started, 1.0)
        self.assertTrue(status["from_cache"])
        self.assertEqual(status["engine_state"]["claude"], "running")
        shown = MOD.display_status(status)
        self.assertRegex(shown["container_state"], r"^up \(since 2026-10-07T09:00:00\) \(cached \d+s ago\)$")
        probe.release.set()
        probe._hub_probe_state["thread"].join(5)
        self.assertEqual(probe.calls, 1)

    def test_fresh_probe_replaces_the_cached_status_and_is_written_back(self):
        probe = self._gated_probe()
        status = MOD.initial_status(probe, ["claude"], self.cache, budget=5.0)
        self.assertEqual(MOD.settle_cached(probe, status), status)
        probe.release.set()
        probe._hub_probe_state["thread"].join(5)
        fresh = MOD.settle_cached(probe, status)
        self.assertNotIn("from_cache", fresh)
        self.assertEqual(fresh["container_state"], "up (since 2026-10-07T10:00:00)")
        self.assertEqual(fresh["engine_state"], {"claude": "down"})
        self.assertEqual(MOD.display_status(fresh), fresh)
        stored = self.cache.load(["claude"])
        self.assertEqual(stored["engine_state"], {"claude": "down"})

    def test_settle_can_wait_for_the_fresh_probe(self):
        probe = self._gated_probe()
        status = MOD.initial_status(probe, ["claude"], self.cache, budget=5.0)
        timer = threading.Timer(0.1, probe.release.set)
        timer.start()
        fresh = MOD.settle_cached(probe, status, budget=5.0, wait=True)
        timer.join()
        self.assertEqual(fresh["engine_state"], {"claude": "down"})

    def test_refresh_during_the_background_probe_keeps_the_cached_view(self):
        probe = self._gated_probe()
        MOD.initial_status(probe, ["claude"], self.cache, budget=5.0)
        thread = probe._hub_probe_state["thread"]
        status = MOD.gather_status(probe, ["claude"], budget=0.05, cache=self.cache)
        self.assertIs(probe._hub_probe_state["thread"], thread)
        self.assertEqual(status["container_state"], "up (since 2026-10-07T09:00:00)")
        probe.release.set()
        thread.join(5)

    def test_miss_falls_back_to_the_budgeted_probe(self):
        empty = MOD.StatusCache(os.path.join(self.tmp.name, "none"), "s")
        status = MOD.initial_status(StubProbeUp(), ["claude"], empty, budget=2.0)
        self.assertNotIn("from_cache", status)
        self.assertEqual(status["engine_state"], {"claude": "running"})

    def test_unknown_results_are_never_cached(self):
        empty = MOD.StatusCache(os.path.join(self.tmp.name, "none"), "s")
        probe = StubProbeDown()
        MOD.initial_status(probe, ["claude"], empty, budget=2.0)
        probe._hub_probe_state["thread"].join(5)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "none")))

    def test_hub_loop_shows_cached_marker_then_fresh_after_refresh(self):
        probe = self._gated_probe()
        out = io.StringIO()
        started = time.time()
        stdin = io.StringIO("r\nq\n")
        timer = threading.Timer(0.2, probe.release.set)
        timer.start()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, probe, stdin, out.write, cache=self.registry_cache)
        timer.join()
        self.assertEqual(rc, 0)
        text = out.getvalue()
        self.assertEqual(text.count("(cached "), 1)
        self.assertLess(text.index("(cached "), text.index("up (since 2026-10-07T10:00:00)"))
        self.assertLess(time.time() - started, 5.0)

    def test_hub_loop_without_cache_is_unchanged(self):
        out = io.StringIO()
        rc = MOD.hub_loop(ROOT, CBOX_PATH, ISOLATED_CTX, StubProbeUp(), io.StringIO("q\n"), out.write)
        self.assertEqual(rc, 0)
        self.assertNotIn("cached", out.getvalue())


class TimingSwitchTests(unittest.TestCase):
    def tearDown(self):
        MOD.timing_setup({})

    def _capture(self, fn):
        import contextlib
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            fn()
        return err.getvalue()

    def test_off_by_default_prints_nothing_and_takes_no_clock_reading(self):
        def run():
            MOD.timing_setup({})
            started = MOD.tstart()
            self.assertEqual(started, 0.0)
            MOD.tend("x", started)
            MOD.tcumulative("y")
            MOD.gather_status(StubProbeUp(), ["claude"], budget=1.0)
        self.assertEqual(self._capture(run), "")

    def test_only_the_value_one_enables_it(self):
        for value in ("0", "", "yes", "true"):
            def run():
                MOD.timing_setup({"CBOX_HUB_TIMING": value})
                MOD.tend("x", MOD.tstart())
            self.assertEqual(self._capture(run), "", value)

    def test_enabled_reports_start_import_and_probe_phases_on_stderr(self):
        def run():
            MOD.timing_setup({"CBOX_HUB_TIMING": "1", "CBOX_HUB_T0": str(int((MOD._T_START - 0.05) * 1000000))})
            MOD.gather_status(StubProbeUp(), ["claude"], budget=1.0)
            MOD.tcumulative("first screen shown")
        text = self._capture(run)
        for label in ("bash plus interpreter start", "python imports", "probe compose ps",
                      "probe inspect (concurrent)", "probe exec scan (concurrent)", "probe total",
                      "first screen shown"):
            self.assertIn("cbox-hub-timing: " + label, text)
        self.assertRegex(text, r"bash plus interpreter start \d+ ms")

    def test_enabled_without_origin_skips_the_bash_line(self):
        text = self._capture(lambda: MOD.timing_setup({"CBOX_HUB_TIMING": "1"}))
        self.assertNotIn("bash plus interpreter start", text)
        self.assertIn("python imports", text)


class LauncherTests(unittest.TestCase):
    def _run(self, hub_source):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("cbox_hub_launch.py",):
                with open(os.path.join(LIB, name), encoding="utf-8") as src:
                    with open(os.path.join(tmp, name), "w", encoding="utf-8") as dst:
                        dst.write(src.read())
            with open(os.path.join(tmp, "cbox_hub.py"), "w", encoding="utf-8") as fh:
                fh.write(hub_source)
            return subprocess.run([sys.executable, os.path.join(tmp, "cbox_hub_launch.py"), "i", "c"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30).returncode

    def test_syntax_error_in_the_hub_maps_to_the_reserved_failure_exit(self):
        self.assertEqual(self._run("def broken(((\n"), 97)

    def test_import_error_maps_to_the_reserved_failure_exit(self):
        self.assertEqual(self._run("import module_that_does_not_exist_anywhere\ndef main(argv):\n    return 0\n"), 97)

    def test_runtime_crash_maps_to_the_reserved_failure_exit(self):
        self.assertEqual(self._run("def main(argv):\n    raise RuntimeError('x')\n"), 97)

    def test_return_codes_pass_through(self):
        self.assertEqual(self._run("def main(argv):\n    return 96\n"), 96)
        self.assertEqual(self._run("def main(argv):\n    return 0\n"), 0)
        self.assertEqual(self._run("import sys\ndef main(argv):\n    sys.exit(5)\n"), 5)

    def test_real_hub_module_imports_cleanly_through_the_launcher_path(self):
        code = ("import sys; sys.path.insert(0, %r); import cbox_hub_launch, cbox_hub; "
                "assert callable(cbox_hub.main)") % LIB
        self.assertEqual(subprocess.run([sys.executable, "-c", code], timeout=30).returncode, 0)


if __name__ == "__main__":
    unittest.main()
