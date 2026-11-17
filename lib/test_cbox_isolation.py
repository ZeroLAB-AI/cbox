import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


INSTALL = Path(__file__).resolve().parents[1]
MODULE = INSTALL / "lib" / "cbox_isolation.py"
SPEC = importlib.util.spec_from_file_location("cbox_isolation", MODULE)
isolation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(isolation)


class IsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.workspace = self.base / "project with spaces"
        self.workspace.mkdir()
        (self.workspace / ".git").mkdir()
        self.args = dict(workspace=str(self.workspace), image="cbox-img:test", session="check", engines=["claude", "codex", "hermes"], uid=1000, gid=1000)

    def render(self, **changes):
        return isolation.render(**{**self.args, **changes})

    def invoke(self, extra=(), gated=True, dispatcher=False, env=None):
        command = ["bash", str(INSTALL / "cbox"), "isolation"] if dispatcher else [sys.executable, str(MODULE)]
        command += ["render", "--workspace", str(self.workspace), "--image", "cbox-img:test", "--session", "check", "--uid", "1000", "--gid", "1000"]
        if gated:
            command.append("--experimental")
        return subprocess.run(command + list(extra), text=True, capture_output=True, timeout=15, env=env)

    def test_engine_storage_is_disjoint_and_workspace_is_only_host_bind(self):
        plan = self.render()
        owners = {}
        for name, service in plan["services"].items():
            engine = service["labels"]["cbox.engine"]
            for mount in service["volumes"]:
                if mount["type"] == "volume":
                    owners.setdefault(mount["source"], set()).add(engine)
                    self.assertTrue(mount["volume"]["nocopy"])
                else:
                    self.assertEqual(mount["source"], str(self.workspace))
                    self.assertEqual(mount["target"], "/workspace")
                    self.assertTrue(mount["read_only"])
                    self.assertFalse(mount["bind"]["create_host_path"])
                    self.assertIn(name, self.args["engines"])
        self.assertEqual(len(owners), 3)
        self.assertTrue(all(len(value) == 1 for value in owners.values()))
        self.assertEqual(set(plan["volumes"]), set(owners))
        self.assertTrue(all("external" not in value and "name" not in value for value in plan["volumes"].values()))

    def test_no_network_host_escape_or_automatic_start(self):
        plan = self.render()
        self.assertNotIn("networks", plan)
        for service in plan["services"].values():
            self.assertEqual(service["network_mode"], "none")
            self.assertEqual(service["profiles"], ["engine-isolation"])
            self.assertEqual(service["pull_policy"], "never")
            self.assertEqual(service["cap_drop"], ["ALL"])
            self.assertEqual(service["security_opt"], ["no-new-privileges:true"])
            self.assertTrue(service["read_only"])
            self.assertTrue(service["healthcheck"]["disable"])
            for key in ("privileged", "devices", "ports", "pid", "ipc", "use_api_socket", "env_file", "extends", "volumes_from", "extra_hosts", "build"):
                self.assertNotIn(key, service)

    def test_initializers_have_no_workspace_and_workers_are_nonroot(self):
        plan = self.render()
        for engine in self.args["engines"]:
            worker = plan["services"][engine]
            self.assertEqual(worker["user"], "1000:1000")
            self.assertNotIn("cap_add", worker)
            self.assertEqual(worker["entrypoint"], ["/bin/sleep"])
            prepare_name, dependency = next(iter(worker["depends_on"].items()))
            self.assertEqual(dependency["condition"], "service_completed_successfully")
            prepare = plan["services"][prepare_name]
            self.assertEqual(prepare["entrypoint"], ["/bin/chown"])
            self.assertEqual(prepare["cap_add"], ["CHOWN"])
            self.assertEqual(len(prepare["volumes"]), 1)
            self.assertEqual(prepare["volumes"][0], worker["volumes"][0])
            self.assertEqual(prepare["command"], [worker["user"], worker["environment"]["HOME"]])

    def test_host_tokens_and_configuration_do_not_influence_output(self):
        env = dict(os.environ)
        env.update(OPENAI_API_KEY="token-canary", ANTHROPIC_API_KEY="token-canary", GEMINI_API_KEY="token-canary", HTTP_PROXY="token-canary", CBOX_HERMES_HOME="token-canary", COMPOSE_FILE="token-canary", CBOX_ANTIGRAVITY="on")
        result = self.invoke(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("token-canary", result.stdout)
        self.assertNotIn("antigravity", result.stdout)
        self.assertEqual(json.loads(result.stdout), self.render())
        self.assertEqual(list(self.workspace.iterdir()), [self.workspace / ".git"])

    def test_scope_changes_do_not_reuse_other_session_or_project_homes(self):
        original = self.render()
        self.assertEqual(original, self.render(engines=list(reversed(self.args["engines"]))))
        self.assertNotEqual(original["name"], self.render(session="other")["name"])
        other = self.base / "other"
        other.mkdir()
        (other / ".git").write_text("gitdir: /unmounted/git/worktrees/other\n", encoding="ascii")
        self.assertNotEqual(original["name"], self.render(workspace=str(other))["name"])

    def test_subset_does_not_render_other_engines(self):
        plan = self.render(engines=["codex"])
        self.assertEqual(set(plan["services"]), {"codex", "codex-home-init"})
        self.assertEqual(set(plan["volumes"]), {"codex-home"})

    def test_unknown_duplicate_empty_engines_fail(self):
        for engines in ([], ["codex", "codex"], ["antigravity"], ["../codex"]):
            with self.subTest(engines=engines), self.assertRaises(ValueError):
                self.render(engines=engines)

    def test_root_negative_and_nonnumeric_identity_fail(self):
        for field in ("uid", "gid"):
            for value in (0, -1, "1000", True, 2147483648):
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.render(**{field: value})

    def test_compose_interpolation_and_shell_input_fail(self):
        for image in ("${IMAGE}", "test\nprivileged: true", "$(touch /tmp/x)", "image;true", ""):
            with self.subTest(image=image), self.assertRaises(ValueError):
                self.render(image=image)
        for session in ("../test", "${SESSION}", "upperCase", "a" * 33, "", "x;true"):
            with self.subTest(session=session), self.assertRaises(ValueError):
                self.render(session=session)

    def test_workspace_traversal_symlink_missing_and_nongit_fail(self):
        linked = self.base / "linked"
        linked.symlink_to(self.workspace, target_is_directory=True)
        for workspace in ("relative", str(linked), str(linked / ".." / self.workspace.name), str(self.base / "missing"), str(self.base), str(self.base / "${HOME}"), str(self.base / "line\nbreak")):
            with self.subTest(workspace=workspace), self.assertRaises(ValueError):
                self.render(workspace=workspace)

    def test_home_and_private_config_roots_fail_even_with_git_marker(self):
        host_home = self.base / "host-home"
        host_home.mkdir()
        (host_home / ".git").mkdir()
        with patch.object(isolation.Path, "home", return_value=host_home):
            for name in ("", ".codex", ".claude", ".claude-cbox", ".gemini", ".hermes", ".hermes-cbox", ".ssh", ".config", ".gnupg", ".docker"):
                private = host_home / name
                if name:
                    private.mkdir()
                    (private / ".git").mkdir()
                with self.subTest(name=name), self.assertRaises(ValueError):
                    self.render(workspace=str(private))
            with self.assertRaises(ValueError):
                self.render(workspace=str(self.base))

    def test_symlink_git_marker_fails(self):
        (self.workspace / ".git").rmdir()
        (self.workspace / ".git").symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.render()

    def test_cli_fails_without_gate_and_never_emits_partial_compose(self):
        for options in ({"gated": False}, {"extra": ["--engine", "antigravity"]}, {"extra": ["--uid", "0"]}):
            with self.subTest(options=options):
                result = self.invoke(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)

    def test_host_dispatcher_reaches_renderer_without_docker(self):
        result = self.invoke(dispatcher=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.render())
        result = self.invoke(dispatcher=True, gated=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
