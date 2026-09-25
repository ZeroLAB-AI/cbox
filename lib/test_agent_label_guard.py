#!/usr/bin/env python3
import fcntl
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GUARD = ROOT / "etc" / "hooks" / "agent_label_guard.py"
BUDGET_MODULE = ROOT / "etc" / "hooks" / "cbox_budget.py"


def hold_all_slots(lock_dir, n):
    os.makedirs(lock_dir, exist_ok=True)
    fds = []
    for i in range(n):
        fd = os.open(os.path.join(lock_dir, "slot.%d" % i), os.O_CREAT | os.O_RDWR, 0o666)
        fcntl.flock(fd, fcntl.LOCK_EX)
        fds.append(fd)
    return fds


def release_slots(fds):
    for fd in fds:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


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
        if k not in ("CBOX_AGENT_MODEL_DENY", "CBOX_AGENT_MODEL_BAN", "CBOX_HERMES_DELEGATE",
                     "CBOX_USAGE_DIR", "CBOX_BUDGET_MODE")
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
        for name in ("worker", "code-reviewer", "debugger", "verifier", "doc-writer"):
            write_agent(self.home, name)
        write_agent(self.home, "alien", model="claude-opus-5-5[1m]", effort="max")

    def test_paid_substitute_without_a_marker_is_refused_while_hermes_local_is_installed(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        for atype in ("worker", "code-reviewer", "debugger", "verifier", "doc-writer"):
            with self.subTest(atype=atype):
                out = run(self.home, atype, "review the diff")
                self.assertEqual(out["permissionDecision"], "deny")
                self.assertIn("hermes-local is installed", out["permissionDecisionReason"])
                self.assertIn("local-skip:", out["permissionDecisionReason"])

    def test_a_local_skip_reason_in_the_description_passes_and_gets_the_label_prefix(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        out = run(self.home, "worker", "local-skip: edge-case-spec - the parser needs the grammar edge cases")
        self.assertEqual(out["permissionDecision"], "allow")
        self.assertTrue(out["updatedInput"]["description"].startswith("worker (sonnet/high): "))

    def test_a_local_verify_marker_in_the_description_passes(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        out = run(self.home, "code-reviewer",
                  "local-verify: confirm the two findings hermes-local reported")
        self.assertEqual(out["permissionDecision"], "allow")

    def test_a_marker_only_in_a_shared_prompt_block_is_refused(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        out = run(self.home, "code-reviewer", "check the local review",
                  prompt="local-verify: hermes-local reviewed this file; confirm its two findings")
        self.assertEqual(out["permissionDecision"], "deny")

    def test_a_reason_without_a_step_justification_is_refused(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        for desc in ("local-skip: cross-cutting", "local-skip: cross-cutting - wave",
                     "local-skip: edge-case-spec: too hard", "local-verify: ok"):
            with self.subTest(desc=desc):
                out = run(self.home, "worker", desc)
                self.assertEqual(out["permissionDecision"], "deny")
                self.assertIn("per step", out["permissionDecisionReason"])

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
                out = run(self.home, "worker", "local-skip: %s - this step needs a frontier model" % reason)
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
        for atype in ("worker", "debugger", "verifier"):
            with self.subTest(atype=atype):
                out = run(self.home, atype, "review the diff",
                          env={"CBOX_HERMES_DELEGATE": "on"})
                self.assertEqual(out["permissionDecision"], "deny")
                self.assertIn("local-skip:", out["permissionDecisionReason"])
        # a closed-list reason still passes under the env gate
        out = run(self.home, "worker", "local-skip: cross-cutting - touches render, gate and probe together",
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

    def test_local_busy_allowed_when_every_slot_is_held(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        lock_dir = tempfile.mkdtemp()
        fds = hold_all_slots(lock_dir, 1)
        try:
            out = run(self.home, "worker",
                      "local-skip: local-busy - hermes is running the extraction step",
                      env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                           "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "1"})
            self.assertEqual(out["permissionDecision"], "allow")
        finally:
            release_slots(fds)

    def test_local_busy_denied_when_a_slot_is_free(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        lock_dir = tempfile.mkdtemp()
        out = run(self.home, "worker",
                  "local-skip: local-busy - hermes is running the extraction step",
                  env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                       "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "1"})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("free", out["permissionDecisionReason"])

    def test_local_busy_denied_when_one_of_two_slots_is_free(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        lock_dir = tempfile.mkdtemp()
        fds = hold_all_slots(lock_dir, 1)
        try:
            out = run(self.home, "worker",
                      "local-skip: local-busy - hermes is running the extraction step",
                      env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                           "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "2"})
            self.assertEqual(out["permissionDecision"], "deny")
            self.assertIn("free", out["permissionDecisionReason"])
        finally:
            release_slots(fds)

    def test_local_busy_denied_when_lock_dir_is_missing(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        missing_dir = os.path.join(tempfile.mkdtemp(), "nope")
        out = run(self.home, "worker",
                  "local-skip: local-busy - hermes is running the extraction step",
                  env={"CBOX_HERMES_DELEGATE_LOCK_DIR": missing_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("free", out["permissionDecisionReason"])


def run_workflow(home, script, env=None):
    payload = {"tool_name": "Workflow", "tool_input": {"script": script}}
    return _run_payload(home, payload, env)


WF_HEAD = "export const meta = {name: 'x', description: 'x'}\n"


class WorkflowLocalFirstTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        write_agent(self.home, "worker")
        write_agent(self.home, "hermes-local", model="haiku", effort="low")

    def test_distinct_step_reasons_pass(self):
        script = WF_HEAD + (
            "await agent(P, {label: 'worker (sonnet/high): local-skip: edge-case-spec - protocol translation with concurrency', agentType: 'worker'})\n"
            "await agent(Q, {label: 'worker (sonnet/high): local-skip: security-gate - reviews the shim input boundary', agentType: 'worker'})\n"
            "await agent(R, {label: 'hermes-local (haiku/low): rename tiers', agentType: 'hermes-local'})\n")
        self.assertIsNone(run_workflow(self.home, script))

    def test_a_reused_wave_reason_is_refused(self):
        script = WF_HEAD + (
            "await agent(P, {label: 'worker: local-skip: cross-cutting - codex app-server migration wave', agentType: 'worker'})\n"
            "await agent(Q, {label: 'worker: local-skip: cross-cutting - codex app-server migration wave', agentType: 'worker'})\n")
        out = run_workflow(self.home, script)
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("reuses the justification", out["permissionDecisionReason"])

    def test_a_paid_step_without_a_label_marker_is_refused(self):
        for label in ("worker: rename the tiers", "worker: local-skip: cross-cutting", "worker: local-skip: cross-cutting - ${WAVE}"):
            with self.subTest(label=label):
                script = WF_HEAD + "await agent(P, {label: `%s`, agentType: 'worker'})\n" % label
                out = run_workflow(self.home, script)
                self.assertEqual(out["permissionDecision"], "deny")
                self.assertIn("per-step local-skip justification", out["permissionDecisionReason"])

    def test_a_marker_in_a_shared_prompt_constant_does_not_count(self):
        script = WF_HEAD + (
            "const COMMON = 'local-skip: cross-cutting - the whole wave is cross-cutting work'\n"
            "await agent(COMMON + ' do step one', {label: 'worker: step one', agentType: 'worker'})\n")
        out = run_workflow(self.home, script)
        self.assertEqual(out["permissionDecision"], "deny")

    def test_workflow_without_hermes_local_is_not_gated(self):
        home = tempfile.mkdtemp()
        write_agent(home, "worker")
        script = WF_HEAD + "await agent(P, {label: 'worker: x', agentType: 'worker'})\n"
        self.assertIsNone(run_workflow(home, script))

    def test_a_script_path_is_read(self):
        path = os.path.join(self.home, "wf.js")
        with open(path, "w", encoding="ascii") as fh:
            fh.write(WF_HEAD + "await agent(P, {label: 'worker: x', agentType: 'worker'})\n")
        out = _run_payload(self.home, {"tool_name": "Workflow", "tool_input": {"scriptPath": path}})
        self.assertEqual(out["permissionDecision"], "deny")

    def test_an_unreadable_script_path_is_refused(self):
        real = os.path.join(self.home, "real.js")
        with open(real, "w", encoding="ascii") as fh:
            fh.write(WF_HEAD + "await agent(P, {label: 'worker: x', agentType: 'worker'})\n")
        link = os.path.join(self.home, "link.js")
        os.symlink(real, link)
        big = os.path.join(self.home, "big.js")
        with open(big, "w", encoding="ascii") as fh:
            fh.write(WF_HEAD + " " * 600000 + "await agent(P, {label: 'worker: x', agentType: 'worker'})\n")
        for path in (os.path.join(self.home, "missing.js"), link, big):
            with self.subTest(path=path):
                out = _run_payload(self.home, {"tool_name": "Workflow", "tool_input": {"scriptPath": path}})
                self.assertEqual(out["permissionDecision"], "deny")
                self.assertIn("could not be read for checking", out["permissionDecisionReason"])

    def test_hermes_review_bypasses_are_closed(self):
        ok = "local-skip: edge-case-spec - protocol translation needs frontier depth"
        cases = {
            "alias": "const A = agent\nawait A(P, {label: 'worker: x', agentType: 'worker'})\n",
            "variable type": "const T = 'worker'\nawait agent(R, {label: 'worker: x', agentType: T})\n",
            "shared options": "const A = {label: '%s', agentType: 'worker'}\nawait agent(P, A)\n" % ok,
            "marker in prompt": "await agent(P, {prompt: `label: '%s'`, label: 'worker: plain', agentType: 'worker'})\n" % ok,
            "off-list reason": "await agent(P, {label: 'worker: local-skip: unavailable-forever - this excuse is not on the list', agentType: 'worker'})\n",
            "label variable": "const L = '%s'\nawait agent(P, {label: L, agentType: 'worker'})\n" % ok,
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                out = run_workflow(self.home, WF_HEAD + body)
                self.assertIsNotNone(out)
                self.assertEqual(out["permissionDecision"], "deny")

    def test_hermes_review_false_denials_are_gone(self):
        ok = "local-skip: cross-cutting - note the renamed agent( helper in this wave"
        cases = {
            "agent( inside a label": "await agent(P, {label: '%s', agentType: 'worker'})\n" % ok,
            "agentType quoted in a prompt": "await agent(P, {prompt: `each call uses agentType: 'worker' for paid work`, label: 'hermes-local: summarize the log', agentType: 'hermes-local'})\n",
            "shape comment": "// shape: agent(X, {label: '%s', agentType: 'worker'})\nawait agent(P, {label: '%s', agentType: 'worker'})\n" % (ok, ok),
            "multi-line call": "await agent(\n  P,\n  {\n    label: \"%s\",\n    agentType: 'worker',\n    phase: 'Build',\n  }\n)\n" % ok,
            "method named agent": "obj.agent(1)\nasync function agent2() {}\n",
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                self.assertIsNone(run_workflow(self.home, WF_HEAD + body))

    def test_distinct_local_busy_steps_run_in_parallel_when_hermes_is_busy(self):
        lock_dir = tempfile.mkdtemp()
        fds = hold_all_slots(lock_dir, 1)
        try:
            script = WF_HEAD + (
                "await agent(P, {label: 'worker: local-skip: local-busy - hermes runs the extraction branch', agentType: 'worker'})\n"
                "await agent(Q, {label: 'worker: local-skip: local-busy - hermes runs the summarization branch', agentType: 'worker'})\n")
            out = run_workflow(self.home, script,
                                env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                                     "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "1"})
            self.assertIsNone(out)
        finally:
            release_slots(fds)

    def test_local_busy_step_is_refused_when_hermes_is_free(self):
        lock_dir = tempfile.mkdtemp()
        script = WF_HEAD + (
            "await agent(P, {label: 'worker: local-skip: local-busy - hermes runs the extraction branch', agentType: 'worker'})\n")
        out = run_workflow(self.home, script,
                            env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("free", out["permissionDecisionReason"])

    def test_malformed_workflow_input_is_refused_not_allowed(self):
        out = _run_payload(self.home, {"tool_name": "Workflow", "tool_input": [1, 2]})
        self.assertEqual(out["permissionDecision"], "deny")
        out = _run_payload(self.home, {"tool_name": "Agent", "tool_input": "worker"})
        self.assertEqual(out["permissionDecision"], "deny")


def write_claude_usage(usage_dir, seven_day_used=None, now=None):
    now = now if now is not None else time.time()
    os.makedirs(usage_dir, exist_ok=True)
    payload = {"captured_at": now}
    if seven_day_used is not None:
        payload["seven_day"] = {"used_percentage": seven_day_used, "resets_at": now + 7 * 24 * 3600}
    with open(os.path.join(usage_dir, "claude.json"), "w", encoding="ascii") as f:
        json.dump(payload, f)


def write_hermes_state(usage_dir, reachable, now=None):
    now = now if now is not None else time.time()
    os.makedirs(usage_dir, exist_ok=True)
    payload = {"ts": now, "last_probe_ts": now, "reachable": reachable,
               "model_loaded": False, "history": [reachable, reachable]}
    with open(os.path.join(usage_dir, "hermes.json"), "w", encoding="ascii") as f:
        json.dump(payload, f)


def write_override(usage_dir, b, until_delta=3600):
    os.makedirs(usage_dir, exist_ok=True)
    with open(os.path.join(usage_dir, "override.json"), "w", encoding="ascii") as f:
        json.dump({"until": time.time() + until_delta, "b": b}, f)


class QuotaGuardTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        write_agent(self.home, "worker")
        self.usage_dir = tempfile.mkdtemp()

    def _run(self, atype, description, env=None, home=None):
        e = {"CBOX_USAGE_DIR": self.usage_dir}
        if env:
            e.update(env)
        return run(home or self.home, atype, description, env=e)

    def test_low_budget_with_hermes_up_is_denied(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=True)
        out = self._run("worker", "review the diff")
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("quota:", out["permissionDecisionReason"])
        self.assertIn("B=0.0", out["permissionDecisionReason"])

    def test_low_budget_without_local_tier_installed_is_allowed(self):
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=True)
        out = self._run("worker", "review the diff")
        self.assertEqual(out["permissionDecision"], "allow")

    def test_security_gate_reason_is_exempt_from_the_quota_deny(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=True)
        out = self._run("worker", "local-skip: security-gate - reviews the shim input boundary")
        self.assertEqual(out["permissionDecision"], "allow")

    def test_owner_explanation_reason_is_exempt_from_the_quota_deny(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=True)
        out = self._run("worker", "local-skip: owner-explanation - marek approved this frontier spawn")
        self.assertEqual(out["permissionDecision"], "allow")

    def test_low_budget_with_hermes_down_is_allowed(self):
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=False)
        out = self._run("worker", "review the diff")
        self.assertEqual(out["permissionDecision"], "allow")

    def test_low_budget_with_hermes_unknown_is_allowed(self):
        write_claude_usage(self.usage_dir, seven_day_used=99)
        out = self._run("worker", "review the diff")
        self.assertEqual(out["permissionDecision"], "allow")

    def test_local_busy_is_refused_below_1_0_even_when_hermes_is_actually_busy(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("cbox_budget_probe", str(BUDGET_MODULE))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        old_env = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir
        try:
            write_claude_usage(self.usage_dir, seven_day_used=59)
            result = mod.budget_for_family("claude")
        finally:
            if old_env is None:
                os.environ.pop("CBOX_USAGE_DIR", None)
            else:
                os.environ["CBOX_USAGE_DIR"] = old_env
        self.assertGreaterEqual(result["b"], 0.5)
        self.assertLess(result["b"], 1.0)
        print("local-busy fixture B=%.3f" % result["b"])

        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_hermes_state(self.usage_dir, reachable=True)
        lock_dir = tempfile.mkdtemp()
        fds = hold_all_slots(lock_dir, 1)
        try:
            out = self._run("worker",
                             "local-skip: local-busy - hermes is running the extraction step",
                             env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                                  "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "1"})
            self.assertEqual(out["permissionDecision"], "deny")
            self.assertIn("quota:", out["permissionDecisionReason"])
            self.assertIn("below 1.0", out["permissionDecisionReason"])
        finally:
            release_slots(fds)

    def test_local_busy_allowed_above_1_0_when_hermes_is_actually_busy(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_override(self.usage_dir, b=2.0)
        write_hermes_state(self.usage_dir, reachable=True)
        lock_dir = tempfile.mkdtemp()
        fds = hold_all_slots(lock_dir, 1)
        try:
            out = self._run("worker",
                             "local-skip: local-busy - hermes is running the extraction step",
                             env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                                  "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "1"})
            self.assertEqual(out["permissionDecision"], "allow")
        finally:
            release_slots(fds)

    def test_override_active_text_is_included_in_the_quota_denial(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_override(self.usage_dir, b=0.1, until_delta=1800)
        write_hermes_state(self.usage_dir, reachable=True)
        out = self._run("worker", "review the diff")
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("quota:", out["permissionDecisionReason"])
        self.assertIn("override active until", out["permissionDecisionReason"])

    def test_workflow_cap_denies_beyond_n_claude_plus_one(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_override(self.usage_dir, b=1.0)
        script = WF_HEAD + (
            "await agent(P, {label: 'worker: local-skip: edge-case-spec - protocol translation with concurrency', agentType: 'worker'})\n"
            "await agent(Q, {label: 'worker: local-skip: security-gate - reviews the shim input boundary', agentType: 'worker'})\n"
            "await agent(R, {label: 'worker: local-skip: cross-cutting - touches render gate and probe together', agentType: 'worker'})\n")
        out = run_workflow(self.home, script, env={"CBOX_USAGE_DIR": self.usage_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("quota-aware cap", out["permissionDecisionReason"])

    def test_workflow_within_cap_is_not_denied_by_quota(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_override(self.usage_dir, b=1.0)
        script = WF_HEAD + (
            "await agent(P, {label: 'worker: local-skip: edge-case-spec - protocol translation with concurrency', agentType: 'worker'})\n"
            "await agent(Q, {label: 'worker: local-skip: security-gate - reviews the shim input boundary', agentType: 'worker'})\n")
        out = run_workflow(self.home, script, env={"CBOX_USAGE_DIR": self.usage_dir})
        self.assertIsNone(out)

    def test_budget_module_missing_falls_back_to_allow(self):
        isolated = tempfile.mkdtemp()
        guard_copy = os.path.join(isolated, "agent_label_guard.py")
        shutil.copy(str(GUARD), guard_copy)
        e = {k: v for k, v in os.environ.items()
             if k not in ("CBOX_AGENT_MODEL_DENY", "CBOX_AGENT_MODEL_BAN", "CBOX_HERMES_DELEGATE",
                          "CBOX_USAGE_DIR", "CBOX_BUDGET_MODE")
             and not (k.startswith("ANTHROPIC_DEFAULT_") and k.endswith("_MODEL"))}
        e["HOME"] = self.home
        e["CBOX_USAGE_DIR"] = self.usage_dir
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=True)
        payload = {"tool_name": "Agent",
                   "tool_input": {"subagent_type": "worker", "description": "review the diff",
                                  "prompt": "do it"}}
        proc = subprocess.run(["python3", guard_copy], input=json.dumps(payload),
                               capture_output=True, text=True, timeout=30, env=e)
        out = json.loads(proc.stdout.strip())["hookSpecificOutput"]
        self.assertEqual(out["permissionDecision"], "allow")


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
