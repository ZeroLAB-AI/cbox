import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import tomllib
import unittest


INSTALL = Path(__file__).resolve().parents[1]
RUNTIME = False


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CBOX_", "CODEX_", "HERMES_", "OLLAMA_", "OPENAI_"))}
        self.env.update(HOME=str(self.root / "home"), INSTALL_DIR=str(INSTALL),
                        CBOX_WORKSPACES=str(self.root / "workspace"), CBOX_USER_DIR="",
                        CBOX_CODEX_MODEL="test-default", CBOX_CODEX_EFFORT="high")
        (self.root / "home").mkdir()
        (self.root / "workspace").mkdir()

    def render(self, gate="off"):
        self.env.update(CBOX_CODEX_HOOKS=gate, CBOX_CODEX_MCP="1")
        out = self.root / "render"
        subprocess.run(["bash", "-c", '. "$INSTALL_DIR/templates/generators.sh"; '
                        'gen_codex_profile_into "$1" global', "test", str(out)],
                       env=self.env, check=True, capture_output=True, text=True)
        return {name: tomllib.loads((out / name).read_text()) for name in (
            "defaults.toml", "managed_config.toml", "requirements.toml",
            "cbox-container.config.toml")}

    def test_preferences_are_defaults_and_never_managed(self):
        d = self.render()
        prefs = d["defaults.toml"]
        self.assertEqual(prefs["model"], "test-default")
        self.assertEqual(prefs["model_reasoning_effort"], "high")
        self.assertIn("tui", prefs)
        self.assertFalse(prefs.keys() & d["managed_config.toml"].keys())
        self.assertEqual(d["cbox-container.config.toml"], dict(d["managed_config.toml"], **prefs,
                         mcp_servers=d["cbox-container.config.toml"]["mcp_servers"]))

    def test_managed_policy_and_exact_mcp_invocation(self):
        d = self.render()
        policy, req = d["managed_config.toml"], d["requirements.toml"]
        self.assertEqual(policy["approval_policy"], "never")
        self.assertEqual(policy["sandbox_mode"], "danger-full-access")
        self.assertFalse(policy["analytics"]["enabled"])
        self.assertFalse(policy["otel"]["log_user_prompt"])
        self.assertIn("notify", policy)
        self.assertEqual(req["allowed_approval_policies"], ["never"])
        self.assertEqual(req["allowed_sandbox_modes"], ["danger-full-access"])
        self.assertEqual(req["default_permissions"], ":danger-full-access")
        self.assertEqual(req["allowed_permission_profiles"], {":danger-full-access": True})
        self.assertEqual(req["mcp_servers"].keys(), policy["mcp_servers"].keys())
        for name, spec in policy["mcp_servers"].items():
            self.assertTrue(spec["enabled"])
            identity = req["mcp_servers"][name]["identity"]["command"]
            self.assertEqual(identity["executable"], spec["command"])
            self.assertEqual(identity["args"], [dict(match="exact", value=a) for a in spec["args"]])

    def test_hooks_cannot_be_replaced_by_user_config(self):
        for gate in ("on", "off"):
            with self.subTest(gate=gate):
                req = self.render(gate)["requirements.toml"]
                self.assertTrue(req["allow_managed_hooks_only"])
                self.assertTrue(req["features"]["hooks"])
                self.assertIn("SessionStart", req["hooks"])
                self.assertEqual("PreToolUse" in req["hooks"], gate == "on")
                self.assertEqual(req["hooks"]["managed_dir"], self.env["HOME"] + "/.claude/hooks")

    def test_empty_mcp_allowlist_when_disabled(self):
        self.render()
        self.env["CBOX_CODEX_MCP"] = "0"
        out = self.root / "empty"
        subprocess.run(["bash", "-c", '. "$INSTALL_DIR/templates/generators.sh"; '
                        'gen_codex_profile_into "$1" global', "test", str(out)],
                       env=self.env, check=True, capture_output=True)
        self.assertEqual(tomllib.loads((out / "requirements.toml").read_text())["mcp_servers"], {})

    def test_mounts_allow_atomic_preferences_and_pin_policy(self):
        install = self.root / "install"
        shutil.copytree(INSTALL, install, ignore=shutil.ignore_patterns("generated", "__pycache__"))
        (install / "image.inputs").write_text("test inputs\n", encoding="ascii")
        for mode in ("mount", "volume"):
            for scope in ("global", "isolated"):
                with self.subTest(mode=mode, scope=scope):
                    eff = self.root / (mode + scope)
                    eff.mkdir()
                    env = dict(self.env, INSTALL_DIR=str(install), CBOX_CODEX_MODE=mode, CBOX_CLAUDE_MODE="volume",
                               CBOX_CODEX_PATH=str(self.root / "home/.codex"), CBOX_SESSION_SCOPE=scope)
                    command = ('gen_compose' if scope == "global" else
                               'gen_compose_isolated "$1" "$2" image hash')
                    subprocess.run(["bash", "-c", '. "$INSTALL_DIR/templates/generators.sh"; ' + command,
                                    "test", str(eff), str(self.root / "workspace")],
                                   env=env, check=True)
                    compose = (install / "docker-compose.yml" if scope == "global" else
                               eff / "docker-compose.yml")
                    text = compose.read_text()
                    self.assertNotIn(':${HOST_HOME}/.codex/config.toml:', text)
                    for name in ("config.toml", "managed_config.toml", "requirements.toml"):
                        self.assertIn(":/etc/codex/" + name + ":ro", text)
                    self.assertIn(':${HOST_HOME}/.codex/AGENTS.override.md:ro', text)
                    self.assertIn(':${HOST_HOME}/.codex/hooks.json:ro', text)

    def server(self, home):
        env = dict(self.env, CODEX_HOME=str(home))
        process = subprocess.Popen([shutil.which("codex"), "--strict-config", "app-server"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=env, text=True)
        self.addCleanup(self.close_server, process)
        self.rpc(process, 1, "initialize", {"clientInfo": {"name": "config-test", "version": "1"},
                                         "capabilities": {"experimentalApi": True}})
        return process

    def close_server(self, process):
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=10)
        process.stdin.close()
        process.stdout.close()

    def rpc(self, process, n, method, params):
        process.stdin.write(json.dumps(dict(id=n, method=method, params=params)) + "\n")
        process.stdin.flush()
        with selectors.DefaultSelector() as poll:
            poll.register(process.stdout, selectors.EVENT_READ)
            for _ in range(100):
                self.assertTrue(poll.select(15), "native config API timed out")
                line = process.stdout.readline()
                self.assertTrue(line, "native config API exited")
                response = json.loads(line)
                if response.get("id") == n:
                    return response
        self.fail("native config API returned too many notifications")

    @unittest.skipUnless(shutil.which("codex"), "native Codex binary unavailable")
    def test_native_preference_write_survives_restart(self):
        home = self.root / "native"
        home.mkdir()
        server = self.server(home)
        for n, key, value in ((2, "model", "saved-choice"), (3, "model_reasoning_effort", "medium"),
                              (4, "tui.status_line", ["git-branch"])):
            response = self.rpc(server, n, "config/value/write", {
                "keyPath": key, "value": value, "mergeStrategy": "replace"})
            self.assertNotIn("error", response, response)
        self.close_server(server)
        server = self.server(home)
        response = self.rpc(server, 5, "config/read", {"includeLayers": True})
        self.assertNotIn("error", response, response)
        config = response["result"]["config"]
        self.assertEqual(config["model"], "saved-choice")
        self.assertEqual(config["model_reasoning_effort"], "medium")
        self.assertEqual(config["tui"]["status_line"], ["git-branch"])
        if RUNTIME:
            for name in ("config.toml", "managed_config.toml", "requirements.toml"):
                path = Path("/etc/codex") / name
                self.assertTrue(path.is_file(), str(path))
                self.assertFalse(os.access(path, os.W_OK), str(path))
            managed = tomllib.loads(Path("/etc/codex/managed_config.toml").read_text())
            self.assertEqual(config["approval_policy"], managed["approval_policy"])
            self.assertEqual(config["sandbox_mode"], managed["sandbox_mode"])
            response = self.rpc(server, 6, "config/value/write", {
                "keyPath": "features.hooks", "value": False, "mergeStrategy": "replace"})
            self.assertIn("error", response, response)
            response = self.rpc(server, 8, "config/value/write", {
                "keyPath": "default_permissions", "value": ":workspace", "mergeStrategy": "replace"})
            self.assertIn("error", response, response)
            (home / "config.toml").write_text('model="saved-choice"\napproval_policy="on-request"\n'
                                             'sandbox_mode="workspace-write"\nnotify=["untrusted"]\n')
            self.close_server(server)
            server = self.server(home)
            response = self.rpc(server, 7, "config/read", {"includeLayers": True})
            self.assertNotIn("error", response, response)
            config = response["result"]["config"]
            for key in ("approval_policy", "sandbox_mode", "notify"):
                self.assertEqual(config[key], managed[key])
            self.assertEqual(config["model"], "saved-choice")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", action="store_true")
    args, rest = parser.parse_known_args()
    RUNTIME = args.runtime
    if RUNTIME:
        if not shutil.which("codex"):
            parser.error("runtime gate requires the native Codex binary")
        unittest.main(argv=[__file__, "SettingsTests.test_native_preference_write_survives_restart"] + rest)
    else:
        unittest.main(argv=[__file__] + rest)
