#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GUARD = ROOT / "etc" / "hooks" / "agent_label_guard.py"


def write_agent(home, name, model="sonnet", effort="high"):
    d = os.path.join(home, ".claude", "agents")
    os.makedirs(d, exist_ok=True)
    body = "---\nname: %s\ndescription: x\nmodel: %s\n" % (name, model)
    if effort:
        body += "effort: %s\n" % effort
    body += "---\nbody\n"
    with open(os.path.join(d, name + ".md"), "w", encoding="ascii") as fh:
        fh.write(body)


def run_with_model(home, atype, model, description, prompt="do it", env=None):
    payload = {
        "tool_name": "Agent",
        "tool_input": {"subagent_type": atype, "description": description,
                       "prompt": prompt, "model": model},
    }
    return _run_payload(home, payload, env)


def run(home, atype, description, prompt="do it", env=None):
    payload = {
        "tool_name": "Agent",
        "tool_input": {"subagent_type": atype, "description": description, "prompt": prompt},
    }
    return _run_payload(home, payload, env)


def _run_payload(home, payload, env=None):
    e = {
        k: v for k, v in os.environ.items()
        if k not in ("CBOX_AGENT_MODEL_DENY", "CBOX_AGENT_MODEL_BAN", "CBOX_HERMES_DELEGATE")
        and not (k.startswith("ANTHROPIC_DEFAULT_") and k.endswith("_MODEL"))
    }
    e["HOME"] = home
    if env:
        e.update(env)
    proc = subprocess.run(
        ["python3", str(GUARD)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=30,
        env=e,
    )
    out = proc.stdout.strip()
    return json.loads(out)["hookSpecificOutput"] if out else None


class LocalFirstGateTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        for name in ("worker", "code-reviewer", "debugger", "test-runner", "doc-writer"):
            write_agent(self.home, name)
        write_agent(self.home, "alien", model="claude-opus-5[1m]", effort="max")

    def test_paid_substitute_without_a_marker_is_refused_while_hermes_local_is_installed(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        for atype in ("worker", "code-reviewer", "debugger", "test-runner", "doc-writer"):
            with self.subTest(atype=atype):
                out = run(self.home, atype, "review the diff")
                self.assertEqual(out["permissionDecision"], "deny")
                self.assertIn("hermes-local is installed", out["permissionDecisionReason"])
                self.assertIn("local-skip:", out["permissionDecisionReason"])

    def test_a_local_skip_reason_in_the_description_passes_and_gets_the_label_prefix(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        out = run(self.home, "worker", "local-skip: edge-case-spec - build the parser")
        self.assertEqual(out["permissionDecision"], "allow")
        self.assertTrue(out["updatedInput"]["description"].startswith("worker (sonnet/high): "))

    def test_a_local_verify_marker_in_the_prompt_passes(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        out = run(self.home, "code-reviewer", "check the local review",
                  prompt="local-verify: hermes-local reviewed this file; confirm its two findings")
        self.assertEqual(out["permissionDecision"], "allow")

    def test_a_marker_without_a_closed_list_reason_is_still_refused(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        for desc in (
            "local-skip:",
            "local-skip: because-it-was-at-hand - review the diff",
            "please explain the local-skip: marker syntax",
            "nonlocal-skip: unavailable",
        ):
            with self.subTest(desc=desc):
                out = run(self.home, "worker", desc)
                self.assertEqual(out["permissionDecision"], "deny")

    def test_every_closed_list_reason_passes(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        for reason in ("unavailable", "verify-failed", "edge-case-spec",
                       "cross-cutting", "owner-explanation", "security-gate"):
            with self.subTest(reason=reason):
                out = run(self.home, "worker", "(local-skip: %s) build it" % reason)
                self.assertEqual(out["permissionDecision"], "allow")

    def test_the_guard_ignores_a_pinned_model_alias_only_when_the_test_strips_it(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        out = run(self.home, "hermes-local", "summarize",
                  env={"ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-9-pinned"})
        self.assertTrue(out["updatedInput"]["description"].startswith("hermes-local (claude-haiku-9-pinned/low): "))

    def test_without_hermes_local_installed_the_paid_spawn_passes_unmarked(self):
        out = run(self.home, "worker", "review the diff")
        self.assertEqual(out["permissionDecision"], "allow")
        self.assertTrue(out["updatedInput"]["description"].startswith("worker (sonnet/high): "))

    def test_delegate_on_env_forces_the_gate_even_when_the_agent_file_is_absent(self):
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude", "agents", "hermes-local.md")))
        for atype in ("worker", "debugger", "test-runner"):
            with self.subTest(atype=atype):
                out = run(self.home, atype, "review the diff",
                          env={"CBOX_HERMES_DELEGATE": "on"})
                self.assertEqual(out["permissionDecision"], "deny")
                self.assertIn("local-skip:", out["permissionDecisionReason"])
        # a closed-list reason still passes under the env gate
        out = run(self.home, "worker", "local-skip: cross-cutting - build it",
                  env={"CBOX_HERMES_DELEGATE": "on"})
        self.assertEqual(out["permissionDecision"], "allow")

    def test_delegate_off_env_does_not_reactivate_the_gate(self):
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude", "agents", "hermes-local.md")))
        for val in ("off", "0", "false", "no", ""):
            with self.subTest(val=val):
                out = run(self.home, "worker", "review the diff",
                          env={"CBOX_HERMES_DELEGATE": val})
                self.assertEqual(out["permissionDecision"], "allow")

    def test_escalation_and_relay_agents_are_not_gated(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        out = run(self.home, "alien", "cross-cutting design")
        self.assertEqual(out["permissionDecision"], "allow")
        out = run(self.home, "hermes-local", "summarize the log")
        self.assertEqual(out["permissionDecision"], "allow")
        self.assertTrue(out["updatedInput"]["description"].startswith("hermes-local (haiku/low): "))

    def test_exempt_builtins_produce_no_output(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        self.assertIsNone(run(self.home, "Explore", "find the callers"))


class ModelDenyTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        write_agent(self.home, "old-opus", model="claude-opus-4-8", effort="max")

    def test_a_denied_model_needs_the_safety_fallback_note(self):
        env = {"CBOX_AGENT_MODEL_DENY": r"opus-4"}
        out = run(self.home, "old-opus", "retry", env=env)
        self.assertEqual(out["permissionDecision"], "deny")
        out = run(self.home, "old-opus", "safety-fallback: retry after the refusal", env=env)
        self.assertEqual(out["permissionDecision"], "allow")


class FableTierTests(unittest.TestCase):
    ENV = {
        "ANTHROPIC_DEFAULT_FABLE_MODEL": "claude-fable-5[1m]",
        "CBOX_AGENT_MODEL_DENY": r"opus-4",
        "CBOX_AGENT_MODEL_BAN": r"fable-5-1",
    }

    def setUp(self):
        self.home = tempfile.mkdtemp()
        write_agent(self.home, "fab-alias", model="fable", effort="high")
        write_agent(self.home, "fab-pinned", model="claude-fable-5[1m]", effort="max")
        write_agent(self.home, "fab-point", model="claude-fable-5-1[1m]", effort="max")

    def test_the_fable_alias_resolves_to_the_pinned_tier(self):
        out = run(self.home, "fab-alias", "design", env=self.ENV)
        self.assertEqual(out["permissionDecision"], "allow")
        self.assertTrue(out["updatedInput"]["description"].startswith("fab-alias (claude-fable-5[1m]/high): "))

    def test_the_pinned_fable_tier_passes(self):
        out = run(self.home, "fab-pinned", "design", env=self.ENV)
        self.assertEqual(out["permissionDecision"], "allow")

    def test_the_point_release_is_banned_even_with_the_safety_fallback_note(self):
        out = run(self.home, "fab-point", "design", env=self.ENV)
        self.assertEqual(out["permissionDecision"], "deny")
        out = run(self.home, "fab-point", "safety-fallback: design", env=self.ENV)
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("ban", out["permissionDecisionReason"])

    def test_an_exempt_agent_with_an_explicit_banned_model_is_denied(self):
        for atype in ("general-purpose", "Explore", "Plan", "fork", ""):
            payload_env = dict(self.ENV)
            out = run_with_model(self.home, atype, "claude-fable-5-1[1m]", "scan", env=payload_env)
            self.assertEqual(out["permissionDecision"], "deny", atype)

    def test_an_exempt_agent_with_a_denied_model_needs_the_note(self):
        out = run_with_model(self.home, "general-purpose", "claude-opus-4-8[1m]", "scan", env=self.ENV)
        self.assertEqual(out["permissionDecision"], "deny")
        out = run_with_model(self.home, "general-purpose", "claude-opus-4-8[1m]",
                             "safety-fallback: retry after the refusal", env=self.ENV)
        self.assertIsNone(out)

    def test_an_unpinned_alias_named_by_the_ban_pattern_is_refused(self):
        env = {k: v for k, v in self.ENV.items() if k != "ANTHROPIC_DEFAULT_FABLE_MODEL"}
        env["ANTHROPIC_DEFAULT_FABLE_MODEL"] = ""
        out = run_with_model(self.home, "general-purpose", "fable", "scan", env=env)
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("not pinned", out["permissionDecisionReason"])
        out = run_with_model(self.home, "general-purpose", "sonnet", "scan", env=env)
        self.assertIsNone(out)

    def test_an_explicit_point_release_override_is_banned_too(self):
        out = run(self.home, "fab-pinned", "design", env=self.ENV)
        self.assertEqual(out["permissionDecision"], "allow")
        payload_env = dict(self.ENV)
        out = run(self.home, "fab-alias", "design", env=dict(payload_env, ANTHROPIC_DEFAULT_FABLE_MODEL="claude-fable-5-1"))
        self.assertEqual(out["permissionDecision"], "deny")


if __name__ == "__main__":
    unittest.main()
