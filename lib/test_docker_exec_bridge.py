#!/usr/bin/env python3
import importlib.util
import json
import os
import socket
import tempfile
import threading
import time
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

    def test_darwin_parent_identity_uses_lstart_and_survives_the_gate(self):
        original = MOD._is_darwin
        MOD._is_darwin = lambda: True
        try:
            lstart = MOD._darwin_parent_start(os.getpid())
            self.assertTrue(lstart)
            self.assertFalse(lstart.isdigit())
            self.assertTrue(MOD.parent_alive(os.getpid(), lstart))
            self.assertTrue(MOD.parent_alive(os.getpid(), "  " + lstart + "  "))
            self.assertFalse(MOD.parent_alive(os.getpid(), "Mon Jan  1 00:00:00 2000"))
            self.assertFalse(MOD.parent_alive(2 ** 31 - 1, lstart))
        finally:
            MOD._is_darwin = original

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
                    records = [json.loads(line) for line in handle if line.strip()]
                self.assertTrue(any(r.get("op") == "list" for r in records))
                record = [r for r in records if r.get("op") == "exec"][-1]
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


    def test_client_present_detects_a_closed_peer(self):
        a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.assertTrue(MOD.client_present(a))
            b.close()
            time.sleep(0.05)
            self.assertFalse(MOD.client_present(a))
        finally:
            a.close()

    def _start_bridge(self, tmp, handler, patches):
        originals = {}
        for name, value in patches.items():
            originals[name] = getattr(MOD, name)
            setattr(MOD, name, value)
        stop = {"value": False}
        originals.setdefault("parent_alive", MOD.parent_alive)
        MOD.parent_alive = lambda pid, start: not stop["value"]
        thread = threading.Thread(target=MOD.serve, args=(tmp, os.getpid(), "1", handler), daemon=True)
        thread.start()
        sock_path = os.path.join(tmp, "bridge.sock")
        deadline = time.monotonic() + 5
        while not os.path.lexists(sock_path) and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(os.path.lexists(sock_path))
        return originals, thread, stop, sock_path

    def _stop_bridge(self, originals, thread, stop):
        stop["value"] = True
        thread.join(5)
        self.assertFalse(thread.is_alive())
        for name, value in originals.items():
            setattr(MOD, name, value)

    def _request(self, sock_path, payload, expect_response=True):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(sock_path)
        try:
            client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            if not expect_response:
                return None
            client.settimeout(5)
            data = b""
            while not data.endswith(b"\n"):
                chunk = client.recv(65536)
                if not chunk:
                    self.fail("bridge stopped serving before answering")
                data += chunk
            return json.loads(data.decode("utf-8"))
        finally:
            client.close()

    def test_bridge_keeps_serving_after_a_client_disconnects_before_response(self):
        with tempfile.TemporaryDirectory() as tmp:
            scope_tmp = os.path.join(tmp, "scope")
            os.makedirs(scope_tmp)
            audit_path = os.path.join(tmp, "audit.jsonl")
            handler = MOD.Handler("docker", ["project_a"], [scope_tmp], 30, 4096, audit_path)
            sock_dir = os.path.join(tmp, "run")
            os.makedirs(sock_dir)
            original_write = MOD.write_response
            first = {"flag": False}

            def failing_write(conn, value):
                if not first["flag"]:
                    first["flag"] = True
                    raise BrokenPipeError("client went away")
                return original_write(conn, value)

            patches = {
                "scoped_containers": lambda docker_bin, networks, roots: {
                    "abc": {"id": "abc", "name": "test", "blockedReason": None}
                },
                "client_present": lambda conn: True,
                "write_response": failing_write,
            }
            originals, thread, stop, sock_path = self._start_bridge(sock_dir, handler, patches)
            try:
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.connect(sock_path)
                client.sendall((json.dumps({"op": "list"}) + "\n").encode("utf-8"))
                client.close()
                payload = self._request(sock_path, {"op": "list"})
                self.assertTrue(first["flag"])
                self.assertTrue(payload["ok"])
                with open(audit_path, encoding="ascii") as handle:
                    records = [json.loads(line) for line in handle if line.strip()]
                self.assertTrue(any(r.get("op") == "client-gone" for r in records))
            finally:
                self._stop_bridge(originals, thread, stop)

    def test_bridge_skips_execution_when_client_is_gone_before_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            scope_tmp = os.path.join(tmp, "scope")
            os.makedirs(scope_tmp)
            audit_path = os.path.join(tmp, "audit.jsonl")
            handler = MOD.Handler("docker", ["project_a"], [scope_tmp], 30, 4096, audit_path)
            sock_dir = os.path.join(tmp, "run")
            os.makedirs(sock_dir)

            def forbidden(*args, **kwargs):
                self.fail("run_exec ran although the client was gone before start")

            patches = {
                "scoped_containers": lambda docker_bin, networks, roots: {
                    "abc": {"id": "abc", "name": "test", "blockedReason": None}
                },
                "client_present": lambda conn: False,
                "run_exec": forbidden,
            }
            originals, thread, stop, sock_path = self._start_bridge(sock_dir, handler, patches)
            try:
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.connect(sock_path)
                client.sendall((json.dumps({"op": "exec", "container": "abc", "argv": ["true"]}) + "\n").encode("utf-8"))
                client.close()
                deadline = time.monotonic() + 5
                records = []
                while time.monotonic() < deadline:
                    if os.path.exists(audit_path):
                        with open(audit_path, encoding="ascii") as handle:
                            records = [json.loads(line) for line in handle if line.strip()]
                    if any(r.get("op") == "client-gone" for r in records):
                        break
                    time.sleep(0.01)
                self.assertTrue(any(r.get("op") == "client-gone" for r in records))
                self.assertFalse(any(r.get("op") == "exec" for r in records))
            finally:
                self._stop_bridge(originals, thread, stop)

    def test_bridge_serves_half_closed_client_that_waits_for_response(self):
        with tempfile.TemporaryDirectory() as tmp:
            scope_tmp = os.path.join(tmp, "scope")
            os.makedirs(scope_tmp)
            audit_path = os.path.join(tmp, "audit.jsonl")
            handler = MOD.Handler("docker", ["project_a"], [scope_tmp], 30, 4096, audit_path)
            sock_dir = os.path.join(tmp, "run")
            os.makedirs(sock_dir)
            executed = {"value": False}

            def execute(docker_bin, container_id, argv, cwd, timeout, max_bytes):
                executed["value"] = True
                return {"ok": True, "rc": 0, "stdout": "ok\n", "stderr": "", "timedOut": False, "truncated": False}

            patches = {
                "scoped_containers": lambda docker_bin, networks, roots: {
                    "abc": {"id": "abc", "name": "test", "blockedReason": None}
                },
                "run_exec": execute,
            }
            originals, thread, stop, sock_path = self._start_bridge(sock_dir, handler, patches)
            try:
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.connect(sock_path)
                client.sendall((json.dumps({"op": "exec", "container": "abc", "argv": ["true"]}) + "\n").encode("utf-8"))
                client.shutdown(socket.SHUT_WR)
                client.settimeout(5)
                data = b""
                while not data.endswith(b"\n"):
                    chunk = client.recv(65536)
                    if not chunk:
                        self.fail("bridge did not answer a half-closed client")
                    data += chunk
                client.close()
                payload = json.loads(data.decode("utf-8"))
                self.assertTrue(payload["ok"])
                self.assertTrue(executed["value"])
            finally:
                self._stop_bridge(originals, thread, stop)

    def test_bridge_survives_a_client_that_closes_before_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            scope_tmp = os.path.join(tmp, "scope")
            os.makedirs(scope_tmp)
            audit_path = os.path.join(tmp, "audit.jsonl")
            handler = MOD.Handler("docker", ["project_a"], [scope_tmp], 30, 4096, audit_path)
            sock_dir = os.path.join(tmp, "run")
            os.makedirs(sock_dir)
            executed = {"value": False}

            def execute(docker_bin, container_id, argv, cwd, timeout, max_bytes):
                executed["value"] = True
                return {"ok": True, "rc": 0, "stdout": "ok\n", "stderr": "", "timedOut": False, "truncated": False}

            patches = {
                "scoped_containers": lambda docker_bin, networks, roots: {
                    "abc": {"id": "abc", "name": "test", "blockedReason": None}
                },
                "run_exec": execute,
            }
            originals, thread, stop, sock_path = self._start_bridge(sock_dir, handler, patches)
            try:
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.connect(sock_path)
                client.sendall((json.dumps({"op": "exec", "container": "abc", "argv": ["true"]}) + "\n").encode("utf-8"))
                client.close()
                deadline = time.monotonic() + 5
                records = []
                while time.monotonic() < deadline:
                    if os.path.exists(audit_path):
                        with open(audit_path, encoding="ascii") as handle:
                            records = [json.loads(line) for line in handle if line.strip()]
                    if any(r.get("op") == "client-gone" for r in records):
                        break
                    time.sleep(0.01)
                if any(r.get("op") == "client-gone" for r in records):
                    self.assertFalse(executed["value"])
                    self.assertFalse(any(r.get("op") == "exec" for r in records))
                else:
                    payload = self._request(sock_path, {"op": "list"})
                    self.assertTrue(payload["ok"])
            finally:
                self._stop_bridge(originals, thread, stop)

    def test_bridge_answers_invalid_error_when_handle_raises_oserror(self):
        with tempfile.TemporaryDirectory() as tmp:
            scope_tmp = os.path.join(tmp, "scope")
            os.makedirs(scope_tmp)
            audit_path = os.path.join(tmp, "audit.jsonl")
            handler = MOD.Handler("docker", ["project_a"], [scope_tmp], 30, 4096, audit_path)

            def broken_handle(request):
                raise OSError("docker binary missing")

            handler.handle = broken_handle
            sock_dir = os.path.join(tmp, "run")
            os.makedirs(sock_dir)
            originals, thread, stop, sock_path = self._start_bridge(sock_dir, handler, {})
            try:
                payload = self._request(sock_path, {"op": "list"})
                self.assertFalse(payload["ok"])
                self.assertEqual(payload["kind"], "invalid")
                self.assertIn("docker binary missing", payload["error"])
                payload2 = self._request(sock_path, {"op": "list"})
                self.assertFalse(payload2["ok"])
                self.assertEqual(payload2["kind"], "invalid")
            finally:
                self._stop_bridge(originals, thread, stop)


if __name__ == "__main__":
    unittest.main()
