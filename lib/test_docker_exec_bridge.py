#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "etc", "container", "docker_exec_bridge.py")
SPEC = importlib.util.spec_from_file_location("docker_exec_bridge", PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


def container_doc(**host_overrides):
    host = {
        "Privileged": False,
        "PidMode": "",
        "IpcMode": "",
        "UTSMode": "",
        "UsernsMode": "",
        "NetworkMode": "bridge",
        "CapAdd": [],
        "Devices": [],
        "SecurityOpt": [],
    }
    host.update(host_overrides)
    return {
        "State": {"Running": True},
        "HostConfig": host,
        "Config": {"Image": "test:latest", "Labels": {}},
        "Mounts": [],
    }


class DockerExecBridgeTests(unittest.TestCase):
    def test_policy_denies_host_control_and_namespace_escape(self):
        self.assertEqual(MOD.unsafe_reason(container_doc(Privileged=True)), "privileged container")
        self.assertEqual(MOD.unsafe_reason(container_doc(PidMode="host")), "PidMode=host")
        self.assertEqual(MOD.unsafe_reason(container_doc(CapAdd=["SYS_ADMIN"])), "dangerous added capability")
        doc = container_doc()
        doc["Mounts"] = [{"Source": "/var/run/docker.sock", "Destination": "/run/docker.sock"}]
        self.assertEqual(MOD.unsafe_reason(doc), "host-control mount")
        doc = container_doc()
        doc["Config"]["Labels"]["cbox.kind"] = "isolated"
        self.assertEqual(MOD.unsafe_reason(doc), "cbox infrastructure container")
        doc = container_doc()
        doc["Config"]["Image"] = "cbox-img:123456789abc"
        self.assertEqual(MOD.unsafe_reason(doc), "cbox infrastructure container")
        doc = container_doc()
        doc["Mounts"] = [{"Type": "bind", "Source": "/etc", "Destination": "/host-etc"}]
        self.assertEqual(MOD.unsafe_reason(doc, ["/workspace"]), "bind mount outside workspace scope")
        doc["Mounts"] = [{"Type": "bind", "Source": "/workspace/app", "Destination": "/app"}]
        self.assertIsNone(MOD.unsafe_reason(doc, ["/workspace"]))
        doc["Mounts"] = [{"Type": "bind", "Source": "/etc", "Destination": "/host-etc"}]
        self.assertIsNone(MOD.unsafe_reason(doc))

    def test_resolver_rejects_ambiguous_prefix(self):
        items = {
            "abc111": {"id": "abc111", "name": "one"},
            "abc222": {"id": "abc222", "name": "two"},
        }
        with self.assertRaises(ValueError):
            MOD.resolve_container(items, "abc")
        with self.assertRaises(ValueError):
            MOD.resolve_container(items, "abc/escape")

    def test_output_sanitizer_removes_terminal_controls(self):
        self.assertEqual(MOD.safe_text("ok\n\x1b[31mred\x07\r\u202espoof"), "ok\n?[31mred???spoof")

    def test_parent_identity_includes_process_start_time(self):
        with open("/proc/%d/stat" % os.getpid(), encoding="ascii") as handle:
            raw = handle.read()
        start = raw[raw.rindex(")") + 2:].split()[19]
        self.assertTrue(MOD.parent_alive(os.getpid(), start))
        self.assertFalse(MOD.parent_alive(os.getpid(), str(int(start) + 1)))

    def test_handler_revalidates_scope_before_exec(self):
        original_scope = MOD.scoped_containers
        original_exec = MOD.run_exec
        calls = []
        try:
            def scope(docker_bin, networks, workspace_roots):
                calls.append(tuple(networks))
                return {"abc": {"id": "abc", "name": "test", "blockedReason": None}}

            def execute(docker_bin, container_id, argv, cwd, timeout, max_bytes):
                return {"ok": True, "rc": 0, "stdout": "ok\n", "stderr": "", "timedOut": False, "truncated": False}

            MOD.scoped_containers = scope
            MOD.run_exec = execute
            with tempfile.TemporaryDirectory() as tmp:
                handler = MOD.Handler("docker", ["project_a"], [tmp], 30, 4096, os.path.join(tmp, "audit.jsonl"))
                listed = handler.handle({"op": "list"})
                result = handler.handle({"op": "exec", "container": "abc", "argv": ["pytest", "-q"]})
                self.assertTrue(listed["ok"])
                self.assertTrue(result["ok"])
                self.assertEqual(calls, [("project_a",), ("project_a",)])
                with open(os.path.join(tmp, "audit.jsonl"), encoding="ascii") as handle:
                    record = json.loads(handle.read())
                self.assertEqual(record["argv0"], "pytest")
                self.assertNotIn("argv", record)
        finally:
            MOD.scoped_containers = original_scope
            MOD.run_exec = original_exec

    def test_blocked_container_never_executes(self):
        original_scope = MOD.scoped_containers
        original_exec = MOD.run_exec
        try:
            MOD.scoped_containers = lambda docker_bin, networks, workspace_roots: {
                "abc": {"id": "abc", "name": "test", "blockedReason": "privileged container"}
            }
            MOD.run_exec = lambda *args: self.fail("run_exec called")
            with tempfile.TemporaryDirectory() as tmp:
                handler = MOD.Handler("docker", ["project_a"], [tmp], 30, 4096, os.path.join(tmp, "audit.jsonl"))
                with self.assertRaises(PermissionError):
                    handler.handle({"op": "exec", "container": "abc", "argv": ["true"]})
        finally:
            MOD.scoped_containers = original_scope
            MOD.run_exec = original_exec

    def test_audit_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "target")
            link = os.path.join(tmp, "audit.jsonl")
            with open(target, "w", encoding="ascii"):
                pass
            os.symlink(target, link)
            with self.assertRaises(OSError):
                MOD.audit(link, {"op": "test"})


if __name__ == "__main__":
    unittest.main()
