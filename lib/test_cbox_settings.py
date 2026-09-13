import importlib.util
import io
import os
import unittest
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "lib", "cbox_settings.py")
SPEC = importlib.util.spec_from_file_location("cbox_settings", PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

REGISTRY = MOD.load_registry(ROOT)
SECTIONS = REGISTRY["sections"]
VARIABLES = MOD.setting_variables(REGISTRY)
VBS = MOD.variables_by_section(VARIABLES)


class RegistryGroupingTests(unittest.TestCase):
    def test_every_section_lands_in_exactly_one_group(self):
        grouped = MOD.group_sections(SECTIONS)
        self.assertEqual(len(grouped), len(SECTIONS))
        counts = Counter(s["id"] for s in grouped)
        for sid, n in counts.items():
            self.assertEqual(n, 1, "section %s appeared %d times" % (sid, n))
        self.assertEqual(set(s["id"] for s in grouped), set(s["id"] for s in SECTIONS))

    def test_grouping_is_ordered_ask_then_auto_then_skip(self):
        grouped = MOD.group_sections(SECTIONS)
        profiles = [MOD.PROFILE_ORDER.get(s.get("profile"), 9) for s in grouped]
        self.assertEqual(profiles, sorted(profiles))
        self.assertIn(0, profiles)
        self.assertIn(1, profiles)
        self.assertIn(2, profiles)

    def test_project_only_filter_excludes_machine_scope(self):
        grouped = MOD.group_sections(SECTIONS, project_only=True)
        self.assertTrue(all(s.get("scope") == "project" for s in grouped))
        self.assertLess(len(grouped), len(SECTIONS))

    def test_global_view_includes_machine_scope(self):
        grouped = MOD.group_sections(SECTIONS, project_only=False)
        self.assertTrue(any(s.get("scope") == "machine" for s in grouped))


class EnumEditorMappingTests(unittest.TestCase):
    def test_enum_choice_maps_to_exact_config_set_argv_without_executing(self):
        mode_var = next(v for v in VARIABLES if v["key"] == "CBOX_MODE")
        self.assertEqual(mode_var["type"]["kind"], "enum")
        choices = mode_var["type"]["values"]
        old_call = MOD.subprocess.call
        MOD.subprocess.call = lambda *a, **k: (_ for _ in ()).throw(
            AssertionError("enum_choice_argv must never execute anything")
        )
        try:
            argv1 = MOD.enum_choice_argv("/x/cbox", mode_var, 1)
            argv2 = MOD.enum_choice_argv("/x/cbox", mode_var, 2)
        finally:
            MOD.subprocess.call = old_call
        self.assertEqual(argv1, ["/x/cbox", "config", "set", "CBOX_MODE=%s" % choices[0]])
        self.assertEqual(argv2, ["/x/cbox", "config", "set", "CBOX_MODE=%s" % choices[1]])

    def test_out_of_range_choice_returns_none(self):
        mode_var = next(v for v in VARIABLES if v["key"] == "CBOX_MODE")
        self.assertIsNone(MOD.enum_choice_argv("/x/cbox", mode_var, 99))
        self.assertIsNone(MOD.enum_choice_argv("/x/cbox", mode_var, 0))

    def test_non_enum_variable_has_no_choices(self):
        name_var = next(v for v in VARIABLES if v["key"] == "CBOX_HERMES_MODEL_NAME")
        self.assertIsNone(MOD.enum_choices(name_var))
        self.assertIsNone(MOD.enum_choice_argv("/x/cbox", name_var, 1))

    def test_enum_or_empty_prepends_empty_choice(self):
        eoe_var = next(
            (v for v in VARIABLES if v.get("type", {}).get("kind") == "enum-or-empty"), None
        )
        self.assertIsNotNone(eoe_var, "no enum-or-empty variable found in the real registry")
        choices = MOD.enum_choices(eoe_var)
        self.assertEqual(choices[0], "")
        argv = MOD.enum_choice_argv("/x/cbox", eoe_var, 1)
        self.assertEqual(argv, ["/x/cbox", "config", "set", "%s=" % eoe_var["key"]])


class ParseDiffOverrideTests(unittest.TestCase):
    def test_canned_diff_yields_overridden_key_set(self):
        canned = (
            "CBOX_EGRESS_MODE=on  base=off  global-now=off\n"
            "CBOX_HERMES_PROVIDER= global  base=anthropic  global-now=anthropic\n"
            "CBOX_HERMES_MODEL_URL=http://x  base=http://y  global-now=http://y  CONFLICT\n"
        )
        keys = MOD.parse_diff_overridden_keys(canned)
        self.assertEqual(
            keys, {"CBOX_EGRESS_MODE", "CBOX_HERMES_PROVIDER", "CBOX_HERMES_MODEL_URL"}
        )

    def test_no_overrides_message_yields_empty_set(self):
        canned = "cbox: no project overrides for /x - every key matches the global profile\n"
        self.assertEqual(MOD.parse_diff_overridden_keys(canned), set())

    def test_empty_text_yields_empty_set(self):
        self.assertEqual(MOD.parse_diff_overridden_keys(""), set())


class ParsePendingTests(unittest.TestCase):
    def test_none_text_yields_empty_map(self):
        self.assertEqual(MOD.parse_pending("none\n"), {})
        self.assertEqual(MOD.parse_pending(""), {})

    def test_pending_lines_parsed_into_map(self):
        canned = "mounts=recreate\nbashrc=shell\n"
        self.assertEqual(MOD.parse_pending(canned), {"mounts": "recreate", "bashrc": "shell"})


class ParseConfigGetAllTests(unittest.TestCase):
    def test_section_headers_skipped_keys_flattened(self):
        canned = "# mode\nCBOX_MODE=global\nCBOX_SESSION_SCOPE=isolated\n# mounts\nCBOX_CLAUDE_MODE=mount\n"
        values = MOD.parse_config_get_all(canned)
        self.assertEqual(
            values,
            {
                "CBOX_MODE": "global",
                "CBOX_SESSION_SCOPE": "isolated",
                "CBOX_CLAUDE_MODE": "mount",
            },
        )


class SideEffectSectionsConsistencyTests(unittest.TestCase):
    def test_side_effect_sections_are_real_section_ids(self):
        real_ids = set(s["id"] for s in SECTIONS)
        missing = set(MOD.SIDE_EFFECT_SECTIONS) - real_ids
        self.assertEqual(missing, set(), "side-effect list names sections absent from settings.json: %s" % missing)

    def test_side_effect_sections_pinned_list(self):
        self.assertEqual(
            set(MOD.SIDE_EFFECT_SECTIONS),
            {
                "bashrc",
                "mounts",
                "workspaces",
                "egress",
                "mcp-servers",
                "agents",
                "claude-md",
                "settings",
                "hooks",
                "codex-mcp",
                "codex-progress",
                "continuity",
            },
        )


class BuildIndexScreenTests(unittest.TestCase):
    def test_pending_and_override_markers_render(self):
        grouped = [
            {"id": "mode", "title": "Mode", "profile": "ask", "scope": "project", "apply_class": "none"},
            {"id": "hermes", "title": "Hermes", "profile": "skip", "scope": "project", "apply_class": "recreate"},
        ]
        vbs = {"hermes": [{"key": "CBOX_HERMES_PROVIDER"}]}
        values = {"CBOX_HERMES_PROVIDER": "anthropic"}
        pending = {"hermes": "recreate"}
        overridden = {"CBOX_HERMES_PROVIDER"}
        screen, rows = MOD.build_index_screen(grouped, vbs, values, pending, overridden, isolated=False)
        self.assertEqual(rows, ["mode", "hermes"])
        self.assertIn("*", screen)
        self.assertIn("^", screen)

    def test_filter_narrows_rows_case_insensitively(self):
        grouped = [
            {"id": "mode", "title": "Mode", "profile": "ask", "scope": "project", "apply_class": "none"},
            {"id": "hermes", "title": "Hermes", "profile": "skip", "scope": "project", "apply_class": "recreate"},
        ]
        screen, rows = MOD.build_index_screen(grouped, {}, {}, {}, set(), isolated=False, filter_text="HER")
        self.assertEqual(rows, ["hermes"])

    def test_isolated_shows_reset_and_derive_keys(self):
        grouped = [{"id": "mode", "title": "Mode", "profile": "ask", "scope": "project", "apply_class": "none"}]
        screen, _rows = MOD.build_index_screen(grouped, {}, {}, {}, set(), isolated=True)
        self.assertIn("r) reset", screen)
        self.assertIn("g) derive from global", screen)

    def test_global_hides_reset_and_derive_keys(self):
        grouped = [{"id": "mode", "title": "Mode", "profile": "ask", "scope": "project", "apply_class": "none"}]
        screen, _rows = MOD.build_index_screen(grouped, {}, {}, {}, set(), isolated=False)
        self.assertNotIn("reset all overrides", screen)


class BuildSectionScreenTests(unittest.TestCase):
    def test_side_effect_section_shows_w_row(self):
        section = {"id": "mounts", "title": "Mounts", "apply_class": "recreate", "scope": "project"}
        screen, rows = MOD.build_section_screen(section, [], {}, {}, set())
        self.assertIn("w) cbox setup update mounts", screen)

    def test_non_side_effect_section_hides_w_row(self):
        section = {"id": "mode", "title": "Mode", "apply_class": "none", "scope": "project"}
        screen, rows = MOD.build_section_screen(section, [], {}, {}, set())
        self.assertNotIn("w) cbox setup update", screen)

    def test_override_mark_rendered_for_overridden_key(self):
        section = {"id": "hermes", "title": "Hermes", "apply_class": "recreate", "scope": "project"}
        var = {"key": "CBOX_HERMES_PROVIDER", "prompt": "provider"}
        screen, rows = MOD.build_section_screen(section, [var], {"CBOX_HERMES_PROVIDER": "anthropic"}, {}, {"CBOX_HERMES_PROVIDER"})
        self.assertEqual(rows, ["CBOX_HERMES_PROVIDER"])
        self.assertIn(")^ CBOX_HERMES_PROVIDER", screen)


class EditValueDispatchTests(unittest.TestCase):
    def test_enum_var_selection_invokes_exact_config_set_argv(self):
        calls = []
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv, cwd=None: calls.append((argv, cwd)) or 0
        try:
            var = {"key": "CBOX_MODE", "type": {"kind": "enum", "values": ["global", "isolated"]}}
            MOD.edit_value("/x/cbox", "/proj", var, io.StringIO("2\n"), lambda s: None)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(calls, [(["/x/cbox", "config", "set", "CBOX_MODE=isolated"], "/proj")])

    def test_free_text_blank_cancels_without_exec(self):
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not exec on blank"))
        try:
            var = {"key": "CBOX_HERMES_MODEL_NAME", "type": {"kind": "nonempty-string"}}
            MOD.edit_value("/x/cbox", "/proj", var, io.StringIO("\n"), lambda s: None)
        finally:
            MOD.subprocess.call = old

    def test_free_text_value_invokes_config_set(self):
        calls = []
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv, cwd=None: calls.append((argv, cwd)) or 0
        try:
            var = {"key": "CBOX_HERMES_MODEL_NAME", "type": {"kind": "nonempty-string"}}
            MOD.edit_value("/x/cbox", "/proj", var, io.StringIO("mymodel\n"), lambda s: None)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(calls, [(["/x/cbox", "config", "set", "CBOX_HERMES_MODEL_NAME=mymodel"], "/proj")])


class FetchFailureWarningTests(unittest.TestCase):
    def test_run_capture_failure_yields_ok_false_and_empty_data(self):
        old = MOD.subprocess.run
        MOD.subprocess.run = lambda *a, **k: (_ for _ in ()).throw(OSError("boom"))
        try:
            values, ok = MOD.cbox_config_get_all("/x/cbox", "/proj")
            pending, pending_ok = MOD.cbox_config_pending("/x/cbox", "/proj")
            overridden, overridden_ok = MOD.cbox_config_diff("/x/cbox", "/proj")
        finally:
            MOD.subprocess.run = old
        self.assertEqual(values, {})
        self.assertFalse(ok)
        self.assertEqual(pending, {})
        self.assertFalse(pending_ok)
        self.assertEqual(overridden, set())
        self.assertFalse(overridden_ok)

    def test_build_header_shows_warning_when_a_fetch_failed(self):
        header = MOD.build_header({"mode": "global"}, None, "/proj", ["cbox config get --all"])
        self.assertIn("cbox: warning - failed to run: cbox config get --all", header)

    def test_build_header_silent_when_nothing_failed(self):
        header = MOD.build_header({"mode": "global"}, None, "/proj", [])
        self.assertNotIn("warning", header)

    def test_build_section_screen_shows_warning_when_a_fetch_failed(self):
        section = {"id": "mode", "title": "Mode", "apply_class": "none", "scope": "project"}
        screen, _rows = MOD.build_section_screen(section, [], {}, {}, set(), ["cbox config pending"])
        self.assertIn("cbox: warning - failed to run: cbox config pending", screen)

    def test_build_section_screen_silent_when_nothing_failed(self):
        section = {"id": "mode", "title": "Mode", "apply_class": "none", "scope": "project"}
        screen, _rows = MOD.build_section_screen(section, [], {}, {}, set())
        self.assertNotIn("warning", screen)


class ReportCallRcTests(unittest.TestCase):
    def test_nonzero_rc_prints_failure_message(self):
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv, cwd=None: 7
        out = []
        try:
            rc = MOD.report_call_rc(["/x/cbox", "setup", "classic"], "/proj", out.append)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 7)
        self.assertEqual(len(out), 1)
        self.assertIn("rc=7", out[0])

    def test_zero_rc_prints_nothing(self):
        old = MOD.subprocess.call
        MOD.subprocess.call = lambda argv, cwd=None: 0
        out = []
        try:
            rc = MOD.report_call_rc(["/x/cbox", "setup", "classic"], "/proj", out.append)
        finally:
            MOD.subprocess.call = old
        self.assertEqual(rc, 0)
        self.assertEqual(out, [])


class ParseArgvTests(unittest.TestCase):
    def test_global_invocation(self):
        parsed = MOD.parse_argv(["cbox_settings.py", "/install", "/install/cbox"])
        self.assertEqual(parsed, {"install_dir": "/install", "cbox_path": "/install/cbox", "root": None})

    def test_local_invocation(self):
        parsed = MOD.parse_argv(["cbox_settings.py", "/install", "/install/cbox", "--local", "/proj"])
        self.assertEqual(parsed, {"install_dir": "/install", "cbox_path": "/install/cbox", "root": "/proj"})

    def test_missing_args_returns_none(self):
        self.assertIsNone(MOD.parse_argv(["cbox_settings.py"]))
        self.assertIsNone(MOD.parse_argv(["cbox_settings.py", "/install"]))

    def test_malformed_local_flag_returns_none(self):
        self.assertIsNone(MOD.parse_argv(["cbox_settings.py", "/install", "/install/cbox", "--bogus", "/proj"]))
        self.assertIsNone(MOD.parse_argv(["cbox_settings.py", "/install", "/install/cbox", "--local"]))


class MainNonTtyTests(unittest.TestCase):
    def test_argument_shortage_returns_1(self):
        self.assertEqual(MOD.main(["cbox_settings.py"]), 1)


if __name__ == "__main__":
    unittest.main()
