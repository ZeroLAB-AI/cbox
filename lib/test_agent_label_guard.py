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

os.environ.pop("CBOX_SUBSCRIPTION_PROFILE", None)
os.environ.pop("CBOX_BUDGET_MODE", None)


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


def write_local_tier(cfg_dir, project=None, disabled=None, top_level=True):
    os.makedirs(cfg_dir, exist_ok=True)
    doc = {}
    if top_level:
        doc["mcpServers"] = {"hermes-local": {"command": "x"}}
    if project:
        doc["projects"] = {project: {"mcpServers": {} if top_level else {"hermes-local": {"command": "x"}},
                                     "disabledMcpServers": disabled or []}}
    with open(os.path.join(cfg_dir, ".claude.json"), "w", encoding="ascii") as fh:
        json.dump(doc, fh)


def write_agent(home, name, model="sonnet", effort="high"):
    if name == "hermes-local":
        write_local_tier(os.path.join(home, ".claude-cfg"))
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
                     "CBOX_USAGE_DIR", "CBOX_BUDGET_MODE", "CBOX_SUBSCRIPTION_PROFILE", "CLAUDE_CONFIG_DIR")
        and not k.startswith("CBOX_BUDGET_")
        and not (k.startswith("ANTHROPIC_DEFAULT_") and k.endswith("_MODEL"))
    }
    e["HOME"] = home
    e["CLAUDE_CONFIG_DIR"] = os.path.join(home, ".claude-cfg")
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

    def test_agent_file_alone_does_not_force_the_gate(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        os.unlink(os.path.join(self.home, ".claude-cfg", ".claude.json"))
        for atype in ("worker", "debugger", "verifier"):
            with self.subTest(atype=atype):
                out = run(self.home, atype, "review the diff")
                self.assertEqual(out["permissionDecision"], "allow")

    def test_delegate_env_alone_does_not_force_the_gate(self):
        for val in ("on", "1", "off", ""):
            with self.subTest(val=val):
                out = run(self.home, "worker", "review the diff",
                          env={"CBOX_HERMES_DELEGATE": val})
                self.assertEqual(out["permissionDecision"], "allow")

    def test_a_top_level_server_in_the_config_forces_the_gate(self):
        write_local_tier(os.path.join(self.home, ".claude-cfg"))
        out = run(self.home, "worker", "review the diff")
        self.assertEqual(out["permissionDecision"], "deny")
        out = run(self.home, "worker", "local-skip: cross-cutting - touches render, gate and probe together")
        self.assertEqual(out["permissionDecision"], "allow")

    def test_config_dir_unset_falls_back_to_the_home_claude_json(self):
        write_local_tier(self.home)
        e = {k: v for k, v in os.environ.items()
             if k not in ("CBOX_AGENT_MODEL_DENY", "CBOX_AGENT_MODEL_BAN", "CBOX_HERMES_DELEGATE",
                          "CBOX_USAGE_DIR", "CBOX_BUDGET_MODE", "CBOX_SUBSCRIPTION_PROFILE", "CLAUDE_CONFIG_DIR")
             and not k.startswith("CBOX_BUDGET_")
             and not (k.startswith("ANTHROPIC_DEFAULT_") and k.endswith("_MODEL"))}
        e["HOME"] = self.home
        payload = {"tool_name": "Agent",
                   "tool_input": {"subagent_type": "worker", "description": "review the diff",
                                  "prompt": "do it"}}
        proc = subprocess.run(["python3", str(GUARD)], input=json.dumps(payload),
                              capture_output=True, text=True, timeout=30, env=e)
        out = json.loads(proc.stdout.strip())["hookSpecificOutput"]
        self.assertEqual(out["permissionDecision"], "deny")

    def test_a_project_scoped_server_matches_the_exact_project_key_only(self):
        cfg = os.path.join(self.home, ".claude-cfg")
        proj = os.path.join(self.home, "proj")
        os.makedirs(os.path.join(proj, "sub"))
        elsewhere = os.path.join(self.home, "elsewhere")
        os.makedirs(elsewhere)
        write_local_tier(cfg, project=proj, top_level=False)
        for cwd, expected in ((proj, "deny"), (os.path.join(proj, "sub"), "allow"), (elsewhere, "allow")):
            with self.subTest(cwd=cwd):
                payload = {"tool_name": "Agent", "cwd": cwd,
                           "tool_input": {"subagent_type": "worker", "description": "review the diff",
                                          "prompt": "do it"}}
                out = _run_payload(self.home, payload)
                self.assertEqual(out["permissionDecision"], expected)

    def test_an_ancestor_disable_does_not_apply_to_a_child_directory(self):
        cfg = os.path.join(self.home, ".claude-cfg")
        proj = os.path.join(self.home, "proj")
        os.makedirs(os.path.join(proj, "sub"))
        write_local_tier(cfg, project=proj, disabled=["hermes-local"], top_level=True)
        payload = {"tool_name": "Agent", "cwd": os.path.join(proj, "sub"),
                   "tool_input": {"subagent_type": "worker", "description": "review the diff", "prompt": "x"}}
        self.assertEqual(_run_payload(self.home, payload)["permissionDecision"], "deny")
        payload["cwd"] = proj
        self.assertEqual(_run_payload(self.home, payload)["permissionDecision"], "allow")

    def test_a_server_listed_in_disabled_mcp_servers_is_absent(self):
        cfg = os.path.join(self.home, ".claude-cfg")
        proj = os.path.join(self.home, "proj")
        os.makedirs(proj)
        write_local_tier(cfg, project=proj, disabled=["hermes-local"], top_level=False)
        payload = {"tool_name": "Agent", "cwd": proj,
                   "tool_input": {"subagent_type": "worker", "description": "review the diff", "prompt": "x"}}
        self.assertEqual(_run_payload(self.home, payload)["permissionDecision"], "allow")
        write_local_tier(cfg, project=proj, disabled=["hermes-local"], top_level=True)
        self.assertEqual(_run_payload(self.home, payload)["permissionDecision"], "allow")

    def test_a_missing_config_file_means_absent(self):
        self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "allow")

    def test_an_unreadable_or_odd_config_means_present(self):
        cfg = os.path.join(self.home, ".claude-cfg")
        path = os.path.join(cfg, ".claude.json")
        os.makedirs(cfg, exist_ok=True)
        with self.subTest(kind="invalid json"):
            with open(path, "w", encoding="ascii") as fh:
                fh.write("{not json")
            self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")
        with self.subTest(kind="partial json"):
            with open(path, "w", encoding="ascii") as fh:
                fh.write('{"mcpServers": {"codex-sol": ')
            self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")
        with self.subTest(kind="non-object json"):
            with open(path, "w", encoding="ascii") as fh:
                fh.write("[1, 2]")
            self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")
        with self.subTest(kind="deep nesting"):
            with open(path, "w", encoding="ascii") as fh:
                fh.write("[" * 100000)
            self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")
        with self.subTest(kind="not utf-8"):
            with open(path, "wb") as fh:
                fh.write(b"\xff\xfe{}")
            self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")
        with self.subTest(kind="directory"):
            os.unlink(path)
            os.mkdir(path)
            self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")
            os.rmdir(path)
        with self.subTest(kind="well-formed without the server"):
            write_local_tier(cfg, top_level=False)
            self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "allow")

    def test_a_symlinked_config_means_present(self):
        cfg = os.path.join(self.home, ".claude-cfg")
        real = os.path.join(self.home, "real.json")
        with open(real, "w", encoding="ascii") as fh:
            json.dump({"mcpServers": {"codex-sol": {}}}, fh)
        os.makedirs(cfg, exist_ok=True)
        os.symlink(real, os.path.join(cfg, ".claude.json"))
        self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")

    def test_an_oversize_config_means_present(self):
        cfg = os.path.join(self.home, ".claude-cfg")
        os.makedirs(cfg, exist_ok=True)
        with open(os.path.join(cfg, ".claude.json"), "w", encoding="ascii") as fh:
            fh.write('{"history": "' + "x" * (8 * 1024 * 1024) + '"}')
        self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")

    def test_a_deleted_working_directory_does_not_crash_the_check(self):
        write_local_tier(os.path.join(self.home, ".claude-cfg"), top_level=False)
        gone = os.path.join(self.home, "gone")
        os.makedirs(gone)
        e = {k: v for k, v in os.environ.items()
             if k not in ("CBOX_AGENT_MODEL_DENY", "CBOX_AGENT_MODEL_BAN", "CBOX_HERMES_DELEGATE",
                          "CBOX_USAGE_DIR", "CBOX_BUDGET_MODE", "CBOX_SUBSCRIPTION_PROFILE", "CLAUDE_CONFIG_DIR")
             and not k.startswith("CBOX_BUDGET_")
             and not (k.startswith("ANTHROPIC_DEFAULT_") and k.endswith("_MODEL"))}
        e["HOME"] = self.home
        e["CLAUDE_CONFIG_DIR"] = os.path.join(self.home, ".claude-cfg")
        payload = {"tool_name": "Agent",
                   "tool_input": {"subagent_type": "worker", "description": "review the diff",
                                  "prompt": "do it"}}
        code = ("import os, subprocess, sys\n"
                "os.chdir(%r); os.rmdir(%r)\n"
                "p = subprocess.run(['python3', %r], input=sys.stdin.read(), capture_output=True, text=True, env=os.environ)\n"
                "sys.stdout.write(p.stdout)\n") % (gone, gone, str(GUARD))
        proc = subprocess.run(["python3", "-c", code], input=json.dumps(payload),
                              capture_output=True, text=True, timeout=30, env=e, cwd=self.home)
        out = json.loads(proc.stdout.strip())["hookSpecificOutput"]
        self.assertEqual(out["permissionDecision"], "deny")

    def test_a_large_config_is_still_read(self):
        cfg = os.path.join(self.home, ".claude-cfg")
        os.makedirs(cfg, exist_ok=True)
        with open(os.path.join(cfg, ".claude.json"), "w", encoding="ascii") as fh:
            json.dump({"history": "x" * 300000, "mcpServers": {"hermes-local": {}}}, fh)
        self.assertEqual(run(self.home, "worker", "review the diff")["permissionDecision"], "deny")

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

    def test_local_busy_step_is_accepted_when_the_script_runs_hermes_local_too(self):
        lock_dir = tempfile.mkdtemp()
        env = {"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir}
        busy = "await agent(P, {label: 'worker: local-skip: local-busy - hermes runs the extraction branch', agentType: 'worker'})\n"
        local = "await agent(R, {label: 'hermes-local (haiku/low): extract fields', agentType: 'hermes-local'})\n"
        for name, body in (("local-first", local + busy), ("local-last", busy + local)):
            with self.subTest(order=name):
                self.assertIsNone(run_workflow(self.home, WF_HEAD + body, env=env))

    def test_parallel_hermes_local_and_local_busy_sibling_are_accepted(self):
        lock_dir = tempfile.mkdtemp()
        script = WF_HEAD + (
            "await Promise.all([\n"
            "  agent(P, {label: 'worker: local-skip: local-busy - hermes runs the extraction branch', agentType: 'worker'}),\n"
            "  agent(R, {label: 'hermes-local (haiku/low): extract fields', agentType: 'hermes-local'}),\n"
            "])\n")
        self.assertIsNone(run_workflow(self.home, script, env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir}))

    def test_a_duplicate_agent_type_key_is_non_literal_and_unlocks_nothing(self):
        lock_dir = tempfile.mkdtemp()
        busy = "await agent(P, {label: 'worker: local-skip: local-busy - hermes runs the extraction branch', agentType: 'worker'})\n"
        dup = "await agent(R, {label: 'x', agentType: 'hermes-local', agentType: 'worker'})\n"
        out = run_workflow(self.home, WF_HEAD + dup + busy, env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("dynamic agentType", out["permissionDecisionReason"])
        out = run_workflow(self.home, WF_HEAD + dup, env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("dynamic agentType", out["permissionDecisionReason"])

    def test_local_busy_sibling_still_needs_its_own_justification(self):
        lock_dir = tempfile.mkdtemp()
        env = {"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir}
        local = "await agent(R, {label: 'hermes-local: extract', agentType: 'hermes-local'})\n"
        out = run_workflow(self.home, WF_HEAD + local + (
            "await agent(P, {label: 'worker: local-skip: local-busy', agentType: 'worker'})\n"), env=env)
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("per-step local-skip justification", out["permissionDecisionReason"])
        same = "await agent(%s, {label: 'worker: local-skip: local-busy - hermes runs the extraction branch', agentType: 'worker'})\n"
        out = run_workflow(self.home, WF_HEAD + local + same % "P" + same % "Q", env=env)
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("reuses the justification", out["permissionDecisionReason"])

    def test_local_busy_is_refused_when_the_script_only_runs_other_agents(self):
        lock_dir = tempfile.mkdtemp()
        script = WF_HEAD + (
            "await agent(R, {label: 'alien: design', agentType: 'alien'})\n"
            "await agent(P, {label: 'worker: local-skip: local-busy - hermes runs the extraction branch', agentType: 'worker'})\n")
        out = run_workflow(self.home, script, env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("free", out["permissionDecisionReason"])

    def test_a_dynamic_or_aliased_hermes_local_type_does_not_unlock_local_busy(self):
        lock_dir = tempfile.mkdtemp()
        busy = "await agent(P, {label: 'worker: local-skip: local-busy - hermes runs the extraction branch', agentType: 'worker'})\n"
        for local in ("await agent(R, {label: 'x', agentType: T})\n",
                      "await obj.agent(R, {label: 'x', agentType: 'hermes-local'})\n",
                      "// agent(R, {agentType: 'hermes-local'})\n"):
            with self.subTest(local=local):
                out = run_workflow(self.home, WF_HEAD + local + busy,
                                   env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir})
                self.assertEqual(out["permissionDecision"], "deny")

    def test_the_single_agent_path_keeps_the_live_slot_check(self):
        lock_dir = tempfile.mkdtemp()
        out = run(self.home, "worker", "local-skip: local-busy - hermes runs the extraction branch",
                  env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("free", out["permissionDecisionReason"])

    def test_a_workflow_is_not_gated_when_the_config_lacks_the_server(self):
        os.unlink(os.path.join(self.home, ".claude-cfg", ".claude.json"))
        script = WF_HEAD + "await agent(P, {label: 'worker: x', agentType: 'worker'})\n"
        self.assertIsNone(run_workflow(self.home, script))

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

    def test_exact_deny_text_and_marker_on_agent_and_workflow(self):
        write_agent(self.home, "hermes-local")
        now = int(time.time())
        reset = now + 7 * 24 * 3600
        write_claude_usage(self.usage_dir, seven_day_used=99, now=now)
        write_hermes_state(self.usage_dir, reachable=True)
        cfg = os.path.join(self.home, ".claude-cbox")
        write_local_tier(cfg)
        sid = "s-123"
        transcript = os.path.join(cfg, "projects", "project", sid + ".jsonl")
        os.makedirs(os.path.dirname(transcript))
        with open(transcript, "w") as fh:
            fh.write('{"type":"user","message":{"content":"first"}}\n')
        env = {"CBOX_USAGE_DIR": self.usage_dir, "CLAUDE_CONFIG_DIR": cfg}
        payload = {"tool_name": "Agent", "session_id": sid, "transcript_path": transcript,
                   "tool_input": {"subagent_type": "worker", "description": "review"}}
        out = _run_payload(self.home, payload, env)
        expected = ("quota: B=0.00 below 0.5 (5h ?%%, 7d 99%%); blocked until %s - "
                    "end your turn, cbox resumes this session then" %
                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(reset)))
        self.assertEqual(out["permissionDecisionReason"], expected)
        marker_path = os.path.join(cfg, "limit-watch", "markers", sid + ".regulator.json")
        with open(marker_path) as fh:
            marker = json.load(fh)
        self.assertEqual(marker["transcript_offset"], os.path.getsize(transcript))
        self.assertEqual(marker["due"], reset + 2)
        payload = {"tool_name": "Workflow", "session_id": sid, "transcript_path": transcript,
                   "tool_input": {"script": WF_HEAD + "await agent(P, {label: 'review', agentType: 'worker'})\n"}}
        out = _run_payload(self.home, payload, env)
        self.assertEqual(out["permissionDecisionReason"], expected)
        self.assertEqual(len(os.listdir(os.path.dirname(marker_path))), 1)
        bad = dict(payload)
        bad["session_id"] = "../bad"
        out = _run_payload(self.home, bad, env)
        self.assertEqual(out["permissionDecisionReason"], expected)
        self.assertEqual(len(os.listdir(os.path.dirname(marker_path))), 1)
        write_override(self.usage_dir, b=2.0)
        os.unlink(marker_path)
        out = _run_payload(self.home, {"tool_name": "Agent", "session_id": sid,
                                      "transcript_path": transcript,
                                      "tool_input": {"subagent_type": "worker", "description": "local-verify: review the completed result carefully"}}, env)
        self.assertEqual(out["permissionDecision"], "allow")
        self.assertFalse(os.path.exists(marker_path))

    def test_low_budget_without_local_tier_is_still_denied_on_the_agent_path(self):
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=True)
        out = self._run("worker", "review the diff")
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertTrue(out["permissionDecisionReason"].startswith("quota: B="))
        self.assertNotIn("hermes", out["permissionDecisionReason"].lower())

    def test_low_budget_without_local_tier_is_still_denied_on_the_workflow_path(self):
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=True)
        script = WF_HEAD + "await agent(P, {label: 'review', agentType: 'worker'})\n"
        out = run_workflow(self.home, script, env={"CBOX_USAGE_DIR": self.usage_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertTrue(out["permissionDecisionReason"].startswith("quota: B="))
        self.assertNotIn("hermes", out["permissionDecisionReason"].lower())

    def test_healthy_budget_without_local_tier_passes_unmarked_on_both_paths(self):
        write_claude_usage(self.usage_dir, seven_day_used=10)
        write_hermes_state(self.usage_dir, reachable=True)
        self.assertEqual(self._run("worker", "review the diff")["permissionDecision"], "allow")
        script = WF_HEAD + "await agent(P, {label: 'review', agentType: 'worker'})\n"
        self.assertIsNone(run_workflow(self.home, script, env={"CBOX_USAGE_DIR": self.usage_dir}))

    def test_local_busy_claim_without_local_tier_still_hits_the_busy_quota_floor(self):
        write_claude_usage(self.usage_dir, seven_day_used=59)
        write_hermes_state(self.usage_dir, reachable=True)
        out = self._run("worker", "local-skip: local-busy - hermes is running the extraction step",
                        env={"CBOX_BUDGET_LOW_7D": "101"})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("below 1.0", out["permissionDecisionReason"])

    def test_workflow_cap_without_local_tier_does_not_mention_hermes(self):
        write_override(self.usage_dir, b=0.6)
        calls = "".join("await agent(P%d, {label: 'step %d', agentType: 'worker'})\n" % (i, i) for i in range(4))
        out = run_workflow(self.home, WF_HEAD + calls, env={"CBOX_USAGE_DIR": self.usage_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertNotIn("hermes", out["permissionDecisionReason"].lower())

    def test_a_guard_crash_is_refused_not_allowed_even_without_the_local_tier(self):
        out = _run_payload(self.home, {"tool_name": "Agent", "tool_input": "worker"})
        self.assertEqual(out["permissionDecision"], "deny")

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

    def test_local_busy_between_quota_floor_and_one_is_denied(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("cbox_budget_probe", str(BUDGET_MODULE))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        old_env = os.environ.get("CBOX_USAGE_DIR")
        os.environ["CBOX_USAGE_DIR"] = self.usage_dir
        old_low = os.environ.get("CBOX_BUDGET_LOW_7D")
        os.environ["CBOX_BUDGET_LOW_7D"] = "101"
        try:
            write_claude_usage(self.usage_dir, seven_day_used=59)
            result = mod.budget_for_family("claude")
        finally:
            if old_low is None:
                os.environ.pop("CBOX_BUDGET_LOW_7D", None)
            else:
                os.environ["CBOX_BUDGET_LOW_7D"] = old_low
            if old_env is None:
                os.environ.pop("CBOX_USAGE_DIR", None)
            else:
                os.environ["CBOX_USAGE_DIR"] = old_env
        self.assertGreaterEqual(result["b"], 0.5)
        self.assertLess(result["b"], 1.0)

        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_hermes_state(self.usage_dir, reachable=True)
        lock_dir = tempfile.mkdtemp()
        fds = hold_all_slots(lock_dir, 1)
        try:
            out = self._run("worker",
                             "local-skip: local-busy - hermes is running the extraction step",
                             env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                                  "CBOX_BUDGET_LOW_7D": "101",
                                  "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "1"})
            self.assertEqual(out["permissionDecision"], "deny")
            self.assertTrue(out["permissionDecisionReason"].startswith(
                "quota: B=%.2f below 1.0" % result["b"]))
        finally:
            release_slots(fds)

    def test_workflow_local_busy_deny_has_unprefixed_quota_text(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_claude_usage(self.usage_dir, seven_day_used=59)
        write_hermes_state(self.usage_dir, reachable=True)
        lock_dir = tempfile.mkdtemp()
        fds = hold_all_slots(lock_dir, 1)
        script = WF_HEAD + (
            "await agent(P, {label: 'worker: local-skip: local-busy - hermes is running the extraction step', agentType: 'worker'})\n")
        try:
            out = run_workflow(self.home, script, env={
                "CBOX_USAGE_DIR": self.usage_dir,
                "CBOX_BUDGET_LOW_7D": "101",
                "CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "1"})
            self.assertEqual(out["permissionDecision"], "deny")
            self.assertTrue(out["permissionDecisionReason"].startswith("quota: B="))
            self.assertIn("below 1.0", out["permissionDecisionReason"])
            self.assertNotIn("agent() #", out["permissionDecisionReason"])
        finally:
            release_slots(fds)

    def test_workflow_local_busy_with_hermes_local_in_script_still_hits_the_quota_floor(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_claude_usage(self.usage_dir, seven_day_used=59)
        write_hermes_state(self.usage_dir, reachable=True)
        lock_dir = tempfile.mkdtemp()
        script = WF_HEAD + (
            "await agent(R, {label: 'hermes-local: extract', agentType: 'hermes-local'})\n"
            "await agent(P, {label: 'worker: local-skip: local-busy - hermes is running the extraction step', agentType: 'worker'})\n")
        out = run_workflow(self.home, script, env={
            "CBOX_USAGE_DIR": self.usage_dir,
            "CBOX_BUDGET_LOW_7D": "101",
            "CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertTrue(out["permissionDecisionReason"].startswith("quota: B="))
        self.assertIn("below 1.0", out["permissionDecisionReason"])

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
                          "CBOX_USAGE_DIR", "CBOX_BUDGET_MODE", "CBOX_SUBSCRIPTION_PROFILE", "CLAUDE_CONFIG_DIR")
             and not k.startswith("CBOX_BUDGET_")
             and not (k.startswith("ANTHROPIC_DEFAULT_") and k.endswith("_MODEL"))}
        e["HOME"] = self.home
        e["CLAUDE_CONFIG_DIR"] = os.path.join(self.home, ".claude-cfg")
        e["CBOX_USAGE_DIR"] = self.usage_dir
        write_claude_usage(self.usage_dir, seven_day_used=99)
        write_hermes_state(self.usage_dir, reachable=True)
        payload = {"tool_name": "Agent",
                   "tool_input": {"subagent_type": "worker",
                                  "description": "local-skip: cross-cutting - touches render, gate and probe together",
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


def write_full_usage(usage_dir, five, seven, five_in=600, seven_in=98 * 3600, now=None):
    now = now if now is not None else time.time()
    os.makedirs(usage_dir, exist_ok=True)
    payload = {"captured_at": now,
               "five_hour": {"used_percentage": five, "resets_at": now + five_in},
               "seven_day": {"used_percentage": seven, "resets_at": now + seven_in}}
    with open(os.path.join(usage_dir, "claude.json"), "w", encoding="ascii") as f:
        json.dump(payload, f)


def write_samples(usage_dir, rows):
    with open(os.path.join(usage_dir, "samples.jsonl"), "w", encoding="ascii") as f:
        for ts, used in rows:
            f.write(json.dumps({"ts": ts, "family": "claude", "five_hour": {"used": None},
                                "seven_day": {"used": used}}) + "\n")


SKIP_DESC = "local-skip: edge-case-spec - implementation against a specification with edge cases"


class FreeVersusBrakeGuardTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        write_agent(self.home, "worker")
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        self.usage_dir = tempfile.mkdtemp()
        write_hermes_state(self.usage_dir, reachable=True)

    def _run(self, description, env=None):
        e = {"CBOX_USAGE_DIR": self.usage_dir}
        if env:
            e.update(env)
        return run(self.home, "worker", description, env=e)

    def _workflow(self, calls, env=None):
        script = WF_HEAD + "".join(
            "await agent(P%d, {label: 'worker: local-skip: edge-case-spec - implementation of specification number %d with edge cases', agentType: 'worker'})\n" % (i, i)
            for i in range(calls))
        e = {"CBOX_USAGE_DIR": self.usage_dir}
        if env:
            e.update(env)
        return run_workflow(self.home, script, env=e)

    def test_free_state_never_denies_a_paid_spawn(self):
        write_full_usage(self.usage_dir, five=45, seven=32)
        out = self._run(SKIP_DESC)
        self.assertEqual(out["permissionDecision"], "allow")

    def test_free_state_has_no_workflow_cap(self):
        write_full_usage(self.usage_dir, five=45, seven=32)
        self.assertIsNone(self._workflow(9))

    def test_free_state_allows_a_local_busy_claim_when_hermes_is_busy(self):
        write_full_usage(self.usage_dir, five=45, seven=32)
        lock_dir = tempfile.mkdtemp()
        fds = hold_all_slots(lock_dir, 1)
        try:
            out = self._run("local-skip: local-busy - hermes is running the extraction step",
                            env={"CBOX_HERMES_DELEGATE_LOCK_DIR": lock_dir,
                                 "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY": "1"})
            self.assertEqual(out["permissionDecision"], "allow")
        finally:
            release_slots(fds)

    def test_low_five_hour_brake_denies(self):
        write_full_usage(self.usage_dir, five=97, seven=20, five_in=3600)
        out = self._run(SKIP_DESC)
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("quota: B=", out["permissionDecisionReason"])

    def test_low_seven_day_brake_denies(self):
        write_full_usage(self.usage_dir, five=10, seven=95)
        out = self._run(SKIP_DESC)
        self.assertEqual(out["permissionDecision"], "deny")

    def test_pace_brake_denies_when_the_budget_runs_below_the_floor(self):
        now = time.time()
        write_full_usage(self.usage_dir, five=20, seven=88, five_in=3 * 3600, now=now)
        write_samples(self.usage_dir, [(now - 3 * 3600 + 60 + 120 * i, 70.0 + 18.0 * i / 89.0) for i in range(90)])
        out = self._run(SKIP_DESC)
        self.assertEqual(out["permissionDecision"], "deny")

    def test_pace_brake_alone_can_cap_the_workflow(self):
        now = time.time()
        write_full_usage(self.usage_dir, five=20, seven=55, five_in=3 * 3600, now=now)
        write_samples(self.usage_dir, [(now - 3 * 3600 + 60 + 120 * i, 25.0 + 30.0 * i / 89.0) for i in range(90)])
        out = self._workflow(9)
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("cap of", out["permissionDecisionReason"])

    def test_brake_with_a_budget_above_the_floor_still_caps_the_workflow(self):
        write_full_usage(self.usage_dir, five=10, seven=59, seven_in=7 * 24 * 3600)
        out = self._workflow(3, env={"CBOX_BUDGET_LOW_7D": "101"})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("cap of 2", out["permissionDecisionReason"])
        self.assertIsNone(self._workflow(2, env={"CBOX_BUDGET_LOW_7D": "101"}))

    def test_raising_the_threshold_env_disables_the_denial(self):
        write_full_usage(self.usage_dir, five=10, seven=95)
        out = self._run(SKIP_DESC, env={"CBOX_BUDGET_LOW_7D": "0"})
        self.assertEqual(out["permissionDecision"], "allow")

    def test_unknown_usage_never_denies(self):
        out = self._run(SKIP_DESC)
        self.assertEqual(out["permissionDecision"], "allow")
        self.assertIsNone(self._workflow(9))

    def test_override_still_wins_over_the_free_state(self):
        write_full_usage(self.usage_dir, five=45, seven=32)
        write_override(self.usage_dir, b=0.1)
        out = self._run(SKIP_DESC)
        self.assertEqual(out["permissionDecision"], "deny")


class WorkflowResumeCapTests(unittest.TestCase):
    BRAKE = {"CBOX_BUDGET_LOW_7D": "101"}

    def setUp(self):
        self.home = tempfile.mkdtemp()
        write_agent(self.home, "worker")
        self.usage_dir = tempfile.mkdtemp()
        write_hermes_state(self.usage_dir, reachable=True)
        self.calls = 4

    def _script(self, calls=None, marked=True):
        n = self.calls if calls is None else calls
        label = ("worker: local-skip: edge-case-spec - implementation of specification number %d with edge cases"
                 if marked else "step %d")
        return WF_HEAD + "".join(
            "await agent(P%d, {label: '%s', agentType: 'worker'})\n" % (i, label % i) for i in range(n))

    def _run(self, tool_input, usage_dir=None, env=None, home=None):
        e = {"CBOX_USAGE_DIR": usage_dir or self.usage_dir}
        e.update(self.BRAKE)
        if env:
            e.update(env)
        payload = {"tool_name": "Workflow", "tool_input": tool_input}
        return _run_payload(home or self.home, payload, e)

    def _tight(self, usage_dir=None):
        write_full_usage(usage_dir or self.usage_dir, five=10, seven=59, seven_in=7 * 24 * 3600)

    def test_new_workflow_over_the_cap_under_a_brake_is_refused(self):
        self._tight()
        out = self._run({"script": self._script()})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("cap of 2", out["permissionDecisionReason"])

    def test_resume_after_n_dropped_is_admitted(self):
        self._tight()
        out = self._run({"script": self._script(), "resumeFromRunId": "wf_a1fb4cd4-4ad"})
        self.assertIsNone(out)

    def test_resume_after_an_account_switch_is_admitted(self):
        other_usage = tempfile.mkdtemp()
        write_hermes_state(other_usage, reachable=True)
        write_full_usage(other_usage, five=10, seven=59, seven_in=7 * 24 * 3600)
        scripts = os.path.join(self.home, "projects", "p", "sid", "workflows", "scripts")
        os.makedirs(scripts)
        path = os.path.join(scripts, "design-wf_a1fb4cd4-4ad.js")
        with open(path, "w", encoding="ascii") as f:
            f.write(self._script())
        out = self._run({"scriptPath": path, "resumeFromRunId": "wf_a1fb4cd4-4ad"}, usage_dir=other_usage)
        self.assertIsNone(out)

    def test_a_stored_run_script_path_is_exempt_without_the_resume_field(self):
        self._tight()
        scripts = os.path.join(self.home, "projects", "p", "sid", "workflows", "scripts")
        os.makedirs(scripts)
        path = os.path.join(scripts, "design-wf_1c0ebc90-c16.js")
        with open(path, "w", encoding="ascii") as f:
            f.write(self._script())
        self.assertIsNone(self._run({"scriptPath": path}))

    def test_an_ordinary_script_path_is_still_capped(self):
        self._tight()
        path = os.path.join(self.home, "adhoc.js")
        with open(path, "w", encoding="ascii") as f:
            f.write(self._script())
        out = self._run({"scriptPath": path})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("cap of 2", out["permissionDecisionReason"])

    def test_empty_resume_field_does_not_exempt(self):
        self._tight()
        out = self._run({"script": self._script(), "resumeFromRunId": ""})
        self.assertEqual(out["permissionDecision"], "deny")

    def test_free_state_applies_no_cap_to_new_or_resumed_runs(self):
        write_full_usage(self.usage_dir, five=45, seven=32)
        self.assertIsNone(self._run({"script": self._script(9)}, env={"CBOX_BUDGET_LOW_7D": "20"}))
        self.assertIsNone(self._run({"script": self._script(9), "resumeFromRunId": "wf_x-1"},
                                    env={"CBOX_BUDGET_LOW_7D": "20"}))

    def test_resume_keeps_the_local_first_label_rules(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        self._tight()
        out = self._run({"script": self._script(marked=False), "resumeFromRunId": "wf_a1fb4cd4-4ad"})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("local-skip", out["permissionDecisionReason"])
        self.assertNotIn("cap of", out["permissionDecisionReason"])

    def test_resume_keeps_the_per_spawn_quota_floor(self):
        write_agent(self.home, "hermes-local", model="haiku", effort="low")
        write_full_usage(self.usage_dir, five=10, seven=97, seven_in=7 * 24 * 3600)
        out = self._run({"script": self._script(), "resumeFromRunId": "wf_a1fb4cd4-4ad"})
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertTrue(out["permissionDecisionReason"].startswith("quota: B="))


class SubscriptionProfileLowCapTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.usage_dir = tempfile.mkdtemp()
        self._old_env = {}
        self._env_stack = []

    def tearDown(self):
        while self._env_stack:
            name, old = self._env_stack.pop()
            if old is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = old

    def _set_env(self, env):
        for name in ("CBOX_USAGE_DIR", "CBOX_BUDGET_MODE",
                     "CBOX_SUBSCRIPTION_PROFILE", "CLAUDE_CONFIG_DIR",
                     "CBOX_BUDGET_LOW_7D"):
            if name not in self._old_env:
                self._old_env[name] = os.environ.get(name)
                self._env_stack.append((name, self._old_env[name]))
            if name in env:
                os.environ[name] = env[name]
            else:
                os.environ.pop(name, None)

    def _probe_guard(self, env):
        import importlib.util
        self._set_env(env)
        spec = importlib.util.spec_from_file_location(
            "agent_label_guard_probe_%d" % id(self), str(GUARD))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def _workflow(self, env, calls):
        mod = self._probe_guard(env)
        script = WF_HEAD + "".join(
            "agent(P%d, {label: 'worker: local-skip: edge-case-spec - implementation of specification number %d with edge cases', agentType: 'worker'})\n"
            % (i, i) for i in range(calls))
        return mod.workflow_violations(script)

    def test_low_profile_mode_off_quota_is_one(self):
        mod = self._probe_guard({"CBOX_USAGE_DIR": self.usage_dir,
                                 "CBOX_BUDGET_MODE": "off",
                                 "CBOX_SUBSCRIPTION_PROFILE": "low"})
        self.assertEqual(mod.quota_n_claude(), 1)

    def test_low_profile_n_zero_quota_is_zero(self):
        write_override(self.usage_dir, b=0.0)
        mod = self._probe_guard({"CBOX_USAGE_DIR": self.usage_dir,
                                 "CBOX_SUBSCRIPTION_PROFILE": "low"})
        self.assertEqual(mod.quota_n_claude(), 0)

    def test_high_profile_mode_off_quota_is_none(self):
        mod = self._probe_guard({"CBOX_USAGE_DIR": self.usage_dir,
                                 "CBOX_BUDGET_MODE": "off",
                                 "CBOX_SUBSCRIPTION_PROFILE": "high"})
        self.assertIsNone(mod.quota_n_claude())

    def test_max_profile_mode_off_quota_is_none(self):
        mod = self._probe_guard({"CBOX_USAGE_DIR": self.usage_dir,
                                 "CBOX_SUBSCRIPTION_PROFILE": "max"})
        self.assertIsNone(mod.quota_n_claude())

    def test_low_profile_mode_off_workflow_three_calls_is_refused(self):
        problems = self._workflow({"CBOX_USAGE_DIR": self.usage_dir,
                                   "CBOX_BUDGET_MODE": "off",
                                   "CBOX_SUBSCRIPTION_PROFILE": "low"}, 3)
        self.assertTrue(any("quota-aware cap" in p for p in problems), problems)

    def test_low_profile_mode_off_workflow_one_call_is_allowed(self):
        problems = self._workflow({"CBOX_USAGE_DIR": self.usage_dir,
                                   "CBOX_BUDGET_MODE": "off",
                                   "CBOX_SUBSCRIPTION_PROFILE": "low"}, 1)
        self.assertEqual(problems, [])

    def test_low_profile_free_usage_quota_is_one(self):
        write_full_usage(self.usage_dir, five=10, seven=10)
        mod = self._probe_guard({"CBOX_USAGE_DIR": self.usage_dir,
                                 "CBOX_SUBSCRIPTION_PROFILE": "low"})
        self.assertEqual(mod.quota_n_claude(), 1)

    def test_low_profile_missing_usage_quota_is_one(self):
        mod = self._probe_guard({"CBOX_USAGE_DIR": tempfile.mkdtemp(),
                                 "CBOX_SUBSCRIPTION_PROFILE": "low"})
        self.assertEqual(mod.quota_n_claude(), 1)

    def test_low_profile_ok_brake_quota_is_one(self):
        write_full_usage(self.usage_dir, five=10, seven=59, seven_in=7 * 24 * 3600)
        mod = self._probe_guard({"CBOX_USAGE_DIR": self.usage_dir,
                                 "CBOX_SUBSCRIPTION_PROFILE": "low",
                                 "CBOX_BUDGET_LOW_7D": "101"})
        self.assertEqual(mod.quota_n_claude(), 1)


if __name__ == "__main__":
    unittest.main()
