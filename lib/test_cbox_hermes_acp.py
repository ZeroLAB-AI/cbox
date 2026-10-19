import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

WRAPPER = os.path.normpath(
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..",
        "etc",
        "hooks",
        "cbox_hermes_acp.py",
    )
)
HERMES_PY = "/opt/hermes/bin/python3"

for _name in list(os.environ):
    if _name.startswith("CBOX_") or _name.startswith("HERMES_") or _name.startswith("FAKE_"):
        del os.environ[_name]

FAKE_FILES = {
    "run_agent.py": """import os

if os.environ.get('FAKE_NO_AIAgent') != '1':
    class AIAgent:
        def __init__(self, *args, **kwargs):
            self.args = tuple(args)
            self.kwargs = dict(kwargs)
            self.ephemeral_system_prompt = kwargs.get('ephemeral_system_prompt')
""",
    "acp_adapter/__init__.py": "",
    "acp_adapter/session.py": """import json
import os


def _make_agent(ephemeral=None, **extra):
    from run_agent import AIAgent
    kwargs = dict(extra)
    if ephemeral is not None:
        kwargs['ephemeral_system_prompt'] = ephemeral
    agent = AIAgent(**kwargs)
    report = os.environ.get('FAKE_SESSION_REPORT')
    if report:
        with open(report, 'w', encoding='ascii') as fh:
            json.dump({'cls': AIAgent.__name__, 'prompt': agent.ephemeral_system_prompt}, fh)
    return agent
""",
    "acp_adapter/entry.py": """import os


def main():
    mode = os.environ.get('FAKE_ENTRY_MODE', '')
    if mode == 'make_agent':
        from acp_adapter.session import _make_agent
        explicit = os.environ.get('FAKE_ENTRY_EXPLICIT_PROMPT')
        if explicit is not None:
            _make_agent(ephemeral=explicit)
        else:
            _make_agent()
    print('acp-protocol-line')
    code = os.environ.get('FAKE_ENTRY_EXIT', '')
    if code:
        return int(code)
    return None
""",
}


def _write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="ascii") as fh:
        fh.write(content)


def _build_fakes(root):
    for rel, content in FAKE_FILES.items():
        _write(os.path.join(root, rel), content)


def _hermes_probe():
    if not os.path.exists(HERMES_PY):
        return False
    try:
        proc = subprocess.run(
            [HERMES_PY, "-c", "import acp_adapter, acp"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
        )
    except Exception:
        return False
    return proc.returncode == 0


class TestCboxHermesAcp(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="cbox_hermes_acp_test.")
        cls.fakes = os.path.join(cls.tmp, "fakes")
        _build_fakes(cls.fakes)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def _run_wrapper(self, extra):
        env = {
            "PATH": os.environ.get("PATH", ""),
            "PYTHONPATH": self.fakes,
        }
        env.update(extra)
        proc = subprocess.run(
            [sys.executable, WRAPPER],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        return (
            proc.returncode,
            proc.stdout.decode("ascii", "replace"),
            proc.stderr.decode("ascii", "replace"),
        )

    def _read_report(self, path):
        with open(path, "r", encoding="ascii") as fh:
            return json.load(fh)

    def test_prompt_delivered_to_agent(self):
        report = os.path.join(self.tmp, "a.json")
        code, out, err = self._run_wrapper(
            {
                "HERMES_EPHEMERAL_SYSTEM_PROMPT": "CBOX-PROMPT-A",
                "FAKE_ENTRY_MODE": "make_agent",
                "FAKE_SESSION_REPORT": report,
            }
        )
        self.assertEqual(code, 0, err)
        data = self._read_report(report)
        self.assertEqual(data["cls"], "_AgentWithEphemeralPrompt")
        self.assertEqual(data["prompt"], "CBOX-PROMPT-A")
        self.assertIn("acp-protocol-line", out)

    def test_explicit_prompt_not_overridden(self):
        report = os.path.join(self.tmp, "b.json")
        code, out, err = self._run_wrapper(
            {
                "HERMES_EPHEMERAL_SYSTEM_PROMPT": "CBOX-PROMPT-B",
                "FAKE_ENTRY_MODE": "make_agent",
                "FAKE_ENTRY_EXPLICIT_PROMPT": "EXPLICIT-B",
                "FAKE_SESSION_REPORT": report,
            }
        )
        self.assertEqual(code, 0, err)
        data = self._read_report(report)
        self.assertEqual(data["cls"], "_AgentWithEphemeralPrompt")
        self.assertEqual(data["prompt"], "EXPLICIT-B")

    def test_env_unset_no_patch_entry_runs(self):
        report = os.path.join(self.tmp, "c.json")
        code, out, err = self._run_wrapper(
            {
                "FAKE_ENTRY_MODE": "make_agent",
                "FAKE_SESSION_REPORT": report,
            }
        )
        self.assertEqual(code, 0, err)
        data = self._read_report(report)
        self.assertEqual(data["cls"], "AIAgent")
        self.assertIsNone(data["prompt"])
        self.assertIn("acp-protocol-line", out)

    def test_missing_patch_point_fails_loudly(self):
        code, out, err = self._run_wrapper(
            {
                "HERMES_EPHEMERAL_SYSTEM_PROMPT": "CBOX-PROMPT-D",
                "FAKE_NO_AIAgent": "1",
            }
        )
        self.assertEqual(code, 3)
        self.assertEqual(out, "")
        self.assertIn("run_agent.AIAgent", err)
        self.assertIn("hermes ACP integration needs an update", err)

    def test_entry_exit_code_propagates(self):
        code, out, err = self._run_wrapper({"FAKE_ENTRY_EXIT": "7"})
        self.assertEqual(code, 7)
        self.assertIn("acp-protocol-line", out)

    def test_wrapper_patches_run_agent_against_fakes(self):
        sys.path.insert(0, self.fakes)
        try:
            spec = importlib.util.spec_from_file_location(
                "cbox_hermes_acp_under_test", WRAPPER
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            import run_agent

            before = run_agent.AIAgent.__name__
            mod._apply_cbox_prompt("CBOX-PROMPT-INPROC")
            after = run_agent.AIAgent.__name__
        finally:
            sys.path.remove(self.fakes)
        self.assertEqual(before, "AIAgent")
        self.assertEqual(after, "_AgentWithEphemeralPrompt")


@unittest.skipUnless(_hermes_probe(), "hermes venv cannot import acp_adapter and acp")
class TestRealHermesPatchPoint(unittest.TestCase):
    def test_patch_point_exists_in_real_hermes(self):
        proc = subprocess.run(
            [
                HERMES_PY,
                "-c",
                "import run_agent; raise SystemExit(0 if hasattr(run_agent, 'AIAgent') else 3)",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr.decode("utf-8", "replace"))


if __name__ == "__main__":
    unittest.main()
