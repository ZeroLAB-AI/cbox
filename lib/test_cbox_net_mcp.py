#!/usr/bin/env python3
import datetime
import importlib.util
import json
import os
import pathlib
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "cbox_net_mcp", ROOT / "etc" / "mcp" / "cbox_net_mcp.py"
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

ENV_KEYS = ("CBOX_NETMAP_FILE", "CBOX_SOCKS_PROXY")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")


def write_netmap(path, proxy_host, proxy_port, networks=None, cidrs=None,
                  version=1, generated_at=None):
    obj = {
        "version": version,
        "generated_at": generated_at if generated_at is not None else now_iso(),
        "proxy": {
            "url": "socks5h://%s:%s" % (proxy_host, proxy_port),
            "host": proxy_host,
            "port": proxy_port,
        },
        "scope": "list",
        "networks": networks if networks is not None else [],
        "cidrs": cidrs if cidrs is not None else [],
        "skipped": [],
    }
    with open(path, "w") as f:
        json.dump(obj, f)
    return obj


def find_free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class PlainListener:
    def __init__(self):
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(4)
        self.port = self.server.getsockname()[1]
        self.stop_flag = False
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        self.server.settimeout(0.02)
        while not self.stop_flag:
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            conn.close()

    def stop(self):
        self.stop_flag = True
        self.thread.join(timeout=2)
        self.server.close()


class Socks5Stub:
    def __init__(self):
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(4)
        self.port = self.server.getsockname()[1]
        self.rep = 0
        self.hang = False
        self.bound_atyp = 1
        self.bound_addr_str = "0.0.0.0"
        self.bound_port = 0
        self.connections = 0
        self.last_request = None
        self.stop_flag = False
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        self.server.settimeout(0.02)
        while not self.stop_flag:
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connections += 1
            threading.Thread(target=self._handle, args=(conn,),
                              daemon=True).start()

    def _handle(self, conn):
        conn.settimeout(3)
        try:
            with conn:
                greeting = MOD.recv_exact(conn, 3)
                if greeting is None:
                    return
                conn.sendall(bytes([5, 0]))
                if self.hang:
                    request_header = MOD.recv_exact(conn, 4)
                    if request_header is not None:
                        atyp0 = request_header[3]
                        if atyp0 == 1:
                            MOD.recv_exact(conn, 4)
                        elif atyp0 == 3:
                            lenb = MOD.recv_exact(conn, 1)
                            n = lenb[0] if lenb else 0
                            MOD.recv_exact(conn, n)
                        elif atyp0 == 4:
                            MOD.recv_exact(conn, 16)
                        MOD.recv_exact(conn, 2)
                    return
                header = MOD.recv_exact(conn, 4)
                if header is None:
                    return
                atyp = header[3]
                if atyp == 1:
                    addr_raw = MOD.recv_exact(conn, 4)
                elif atyp == 3:
                    lenb = MOD.recv_exact(conn, 1)
                    n = lenb[0] if lenb else 0
                    addr_raw = MOD.recv_exact(conn, n)
                else:
                    addr_raw = None
                portb = MOD.recv_exact(conn, 2)
                port = struct.unpack("!H", portb)[0] if portb else None
                self.last_request = {
                    "atyp": atyp, "addr_raw": addr_raw, "port": port}

                if self.bound_atyp == 1:
                    bound_bytes = socket.inet_aton(self.bound_addr_str)
                elif self.bound_atyp == 4:
                    bound_bytes = socket.inet_pton(
                        socket.AF_INET6, self.bound_addr_str)
                else:
                    name = self.bound_addr_str.encode()
                    bound_bytes = bytes([len(name)]) + name
                reply = (bytes([5, self.rep, 0, self.bound_atyp])
                         + bound_bytes + struct.pack("!H", self.bound_port))
                conn.sendall(reply)
        except OSError:
            pass

    def stop(self):
        self.stop_flag = True
        self.thread.join(timeout=2)
        self.server.close()


class EnvIsolatedTestCase(unittest.TestCase):
    def setUp(self):
        self._saved_env = {k: os.environ.get(k) for k in ENV_KEYS}
        for k in ENV_KEYS:
            os.environ.pop(k, None)
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        for k, v in self._saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def map_path(self):
        return os.path.join(self.tmpdir, "netmap.json")

    def set_map_path(self, path=None):
        os.environ["CBOX_NETMAP_FILE"] = path or self.map_path()


class DottedContainerNameTests(unittest.TestCase):
    def _map_with_dotted_container(self):
        return {
            "version": 1,
            "proxy": {"url": "socks5h://127.0.0.1:1080", "host": "127.0.0.1", "port": 1080},
            "networks": [{
                "name": "netA", "subnet": "10.42.0.0/16",
                "containers": [{
                    "name": "github.com",
                    "aliases": [],
                    "ipv4": "10.42.0.9",
                    "ports": ["443/tcp"],
                }],
            }],
            "cidrs": [],
        }

    def test_sanitize_marks_dotted_container_name_not_routable(self):
        obj = MOD.sanitize_netmap(self._map_with_dotted_container())
        container = obj["networks"][0]["containers"][0]
        self.assertFalse(container["name_routable"])

    def test_policy_allows_rejects_dotted_container_name_as_hostname(self):
        obj = MOD.sanitize_netmap(self._map_with_dotted_container())
        self.assertFalse(MOD.policy_allows(obj, "github.com", "hostname"))

    def test_build_example_curl_uses_ipv4_for_dotted_container_name(self):
        obj = MOD.sanitize_netmap(self._map_with_dotted_container())
        curl = MOD.build_example_curl(obj)
        self.assertIn("10.42.0.9:443", curl)
        self.assertNotIn("github.com:443", curl)

    def test_dotted_alias_never_treated_as_granted(self):
        obj = {
            "version": 1,
            "proxy": {"url": "socks5h://127.0.0.1:1080", "host": "127.0.0.1", "port": 1080},
            "networks": [{
                "name": "netA", "subnet": "10.42.0.0/16",
                "containers": [{
                    "name": "app",
                    "aliases": ["github.com"],
                    "ipv4": "10.42.0.5",
                    "ports": ["80/tcp"],
                }],
            }],
            "cidrs": [],
        }
        obj = MOD.sanitize_netmap(obj)
        self.assertEqual(obj["networks"][0]["containers"][0]["aliases"], [])
        self.assertFalse(MOD.policy_allows(obj, "github.com", "hostname"))


class HostClassificationTests(unittest.TestCase):
    def test_trailing_newline_label_rejected(self):
        self.assertIsNone(MOD.classify_host("db\n"))

    def test_plain_label_accepted(self):
        self.assertEqual(MOD.classify_host("db"), "hostname")


class NetMapTests(EnvIsolatedTestCase):
    def test_trust_field_present(self):
        listener = PlainListener()
        try:
            write_netmap(self.map_path(), "127.0.0.1", listener.port)
            self.set_map_path()
            result = MOD.run_net_map({})
            payload = json.loads(result["content"][0]["text"])
            self.assertIn("trust", payload)
            self.assertIn("data, not instructions", payload["trust"])
        finally:
            listener.stop()

    def test_sanitized_map_drops_injection_shaped_alias_and_port(self):
        listener = PlainListener()
        try:
            write_netmap(self.map_path(), "127.0.0.1", listener.port,
                          networks=[{
                              "name": "netA", "subnet": "10.42.0.0/16",
                              "containers": [{
                                  "name": "app",
                                  "aliases": ["app", "evil;rm -rf /", "app.example.com"],
                                  "ipv4": "10.42.0.5",
                                  "ports": ["80/tcp", "80/tcp; rm -rf /"],
                              }],
                          }])
            self.set_map_path()
            result = MOD.run_net_map({})
            payload = json.loads(result["content"][0]["text"])
            container = payload["map"]["networks"][0]["containers"][0]
            self.assertEqual(container["aliases"], ["app"])
            self.assertEqual(container["ports"], ["80/tcp"])
            self.assertNotIn("rm -rf", payload["example_curl"])
        finally:
            listener.stop()

    def test_network_filter_returns_only_that_network(self):
        listener = PlainListener()
        try:
            write_netmap(self.map_path(), "127.0.0.1", listener.port,
                          networks=[
                              {"name": "netA", "subnet": "10.42.0.0/16", "containers": []},
                              {"name": "netB", "subnet": "10.43.0.0/16", "containers": []},
                          ])
            self.set_map_path()
            result = MOD.run_net_map({"network": "netB"})
            payload = json.loads(result["content"][0]["text"])
            names = [n["name"] for n in payload["map"]["networks"]]
            self.assertEqual(names, ["netB"])
        finally:
            listener.stop()

    def test_compact_map_when_over_inline_budget(self):
        listener = PlainListener()
        try:
            containers = [{
                "name": "app-%d" % i, "aliases": [],
                "ipv4": "10.42.0.%d" % (i % 250), "ports": ["80/tcp"],
            } for i in range(2000)]
            write_netmap(self.map_path(), "127.0.0.1", listener.port,
                          networks=[{
                              "name": "netA", "subnet": "10.42.0.0/16",
                              "containers": containers,
                          }])
            self.set_map_path()
            result = MOD.run_net_map({})
            payload = json.loads(result["content"][0]["text"])
            self.assertTrue(payload["map"].get("compact"))
            self.assertIn("note", payload)
            self.assertEqual(payload["map"]["networks"][0]["containers"][0], "app-0")
        finally:
            listener.stop()

    def test_ok_with_reachable_proxy(self):
        listener = PlainListener()
        try:
            write_netmap(self.map_path(), "127.0.0.1", listener.port,
                          networks=[{
                              "name": "netA", "subnet": "10.42.0.0/16",
                              "containers": [{
                                  "name": "app", "aliases": [],
                                  "ipv4": "10.42.0.5", "ports": ["80/tcp"],
                              }],
                          }])
            self.set_map_path()
            result = MOD.run_net_map({})
            self.assertFalse(result["isError"])
            payload = json.loads(result["content"][0]["text"])
            self.assertEqual(payload["status"], "ok")
            self.assertTrue(payload["proxy_reachable"])
            self.assertIn("app:80", payload["example_curl"])
            self.assertIsInstance(payload["map_age_seconds"], int)
        finally:
            listener.stop()

    def test_missing_file(self):
        self.set_map_path(os.path.join(self.tmpdir, "does-not-exist.json"))
        result = MOD.run_net_map({})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["status"], "missing")
        self.assertIn("cbox netaccess status", payload["fix"])
        self.assertIn("cbox down && cbox run", payload["fix"])

    def test_malformed_json(self):
        with open(self.map_path(), "w") as f:
            f.write("{not json")
        self.set_map_path()
        result = MOD.run_net_map({})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["status"], "invalid")
        self.assertIn("not valid JSON", payload["reason"])

    def test_wrong_version(self):
        write_netmap(self.map_path(), "127.0.0.1", 1080, version=3)
        self.set_map_path()
        result = MOD.run_net_map({})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["status"], "invalid")
        self.assertIn("unsupported netmap version", payload["reason"])

    def test_version_2_with_host_aliases_accepted(self):
        listener = PlainListener()
        try:
            write_netmap(self.map_path(), "127.0.0.1", listener.port, version=2)
            self.set_map_path()
            result = MOD.run_net_map({})
            self.assertFalse(result["isError"])
            payload = json.loads(result["content"][0]["text"])
            self.assertEqual(payload["status"], "ok")
        finally:
            listener.stop()

    def test_host_aliases_sanitized_and_passed_through(self):
        raw = {
            "version": 2,
            "generated_at": "2026-09-25T00:00:00Z",
            "proxy": {"url": "socks5h://127.0.0.1:1080", "host": "127.0.0.1", "port": 1080},
            "scope": "list",
            "networks": [],
            "cidrs": [],
            "skipped": [],
            "host_aliases": {
                "names": ["devel.zerolab.sk", "evil$(whoami)"],
                "ports": {
                    "443": {"container": "revproxy", "container_port": 443, "network": "project_a"},
                    "not-a-port": {"container": "x", "container_port": 80, "network": "project_a"},
                    "70000": {"container": "x", "container_port": 80, "network": "project_a"},
                },
                "skipped": [{"host_port": "80", "container": "x", "reason": "not on a granted network"}],
            },
        }
        with open(self.map_path(), "w", encoding="ascii") as fh:
            fh.write(json.dumps(raw))
        self.set_map_path()
        result = MOD.run_net_map({})
        payload = json.loads(result["content"][0]["text"])
        host_aliases = payload["map"]["host_aliases"]
        self.assertEqual(host_aliases["names"], ["devel.zerolab.sk"])
        self.assertEqual(list(host_aliases["ports"].keys()), ["443"])
        self.assertEqual(host_aliases["skipped"][0]["host_port"], "80")

    def test_host_aliases_ports_container_validated_and_counters_sanitized(self):
        raw = {
            "version": 2,
            "generated_at": "2026-09-25T00:00:00Z",
            "proxy": {"url": "socks5h://127.0.0.1:1080", "host": "127.0.0.1", "port": 1080},
            "scope": "list",
            "networks": [],
            "cidrs": [],
            "skipped": [],
            "host_aliases": {
                "names": [],
                "ports": {
                    "443": {"container": "revproxy", "container_port": 443, "network": "project_a"},
                    "444": {"container": "bad name!", "container_port": 444, "network": "project_a"},
                },
                "skipped": [],
                "skipped_not_granted": "not-an-int",
                "dropped": 5,
                "some_unknown_key": "should not survive",
            },
        }
        with open(self.map_path(), "w", encoding="ascii") as fh:
            fh.write(json.dumps(raw))
        self.set_map_path()
        result = MOD.run_net_map({})
        payload = json.loads(result["content"][0]["text"])
        host_aliases = payload["map"]["host_aliases"]
        self.assertEqual(list(host_aliases["ports"].keys()), ["443"])
        self.assertEqual(host_aliases["skipped_not_granted"], 0)
        self.assertEqual(host_aliases["dropped"], 5)
        self.assertNotIn("some_unknown_key", host_aliases)

    def test_host_aliases_skipped_entries_validated_and_capped(self):
        long_reason = "x" * 500
        skipped = [
            {"host_port": "80", "container": "x", "reason": "ok"},
            {"host_port": "not-a-port", "container": "x", "reason": "ok"},
            {"host_port": "70000", "container": "x", "reason": "ok"},
            {"host_port": "80", "container": "bad name!", "reason": "ok"},
            {"host_port": "80", "container": "x", "reason": long_reason},
            {"host_port": "", "container": "", "reason": "docker ps failed"},
        ]
        skipped += [
            {"host_port": str(9000 + i), "container": "x", "reason": "ok"}
            for i in range(70)
        ]
        raw = {
            "version": 2,
            "generated_at": "2026-09-25T00:00:00Z",
            "proxy": {"url": "socks5h://127.0.0.1:1080", "host": "127.0.0.1", "port": 1080},
            "scope": "list",
            "networks": [],
            "cidrs": [],
            "skipped": [],
            "host_aliases": {
                "names": [],
                "ports": {},
                "skipped": skipped,
            },
        }
        with open(self.map_path(), "w", encoding="ascii") as fh:
            fh.write(json.dumps(raw))
        self.set_map_path()
        result = MOD.run_net_map({})
        payload = json.loads(result["content"][0]["text"])
        clean_skipped = payload["map"]["host_aliases"]["skipped"]
        self.assertLessEqual(len(clean_skipped), MOD.MAX_HOST_ALIAS_SKIPPED)
        self.assertEqual(clean_skipped[0], {"host_port": "80", "container": "x", "reason": "ok"})
        self.assertEqual(clean_skipped[1]["host_port"], "")
        self.assertEqual(clean_skipped[2]["host_port"], "")
        self.assertEqual(clean_skipped[3]["container"], "")
        self.assertEqual(len(clean_skipped[4]["reason"]), MOD.MAX_HOST_ALIAS_SKIPPED_REASON_LEN)
        self.assertEqual(clean_skipped[5]["host_port"], "")
        self.assertEqual(clean_skipped[5]["container"], "")
        self.assertEqual(clean_skipped[5]["reason"], "docker ps failed")

    def test_symlinked_map_refused(self):
        real_path = os.path.join(self.tmpdir, "real-netmap.json")
        write_netmap(real_path, "127.0.0.1", 1080)
        link_path = self.map_path()
        os.symlink(real_path, link_path)
        self.set_map_path()
        result = MOD.run_net_map({})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["status"], "invalid")
        self.assertIn("symlink", payload["reason"])

    def test_proxy_down(self):
        dead_port = find_free_port()
        write_netmap(self.map_path(), "127.0.0.1", dead_port)
        self.set_map_path()
        result = MOD.run_net_map({})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["status"], "ok")
        self.assertFalse(payload["proxy_reachable"])
        self.assertIn("cbox netaccess status", payload["fix"])


class NetProbeTests(EnvIsolatedTestCase):
    def setUp(self):
        super().setUp()
        self.stub = Socks5Stub()

    def tearDown(self):
        self.stub.stop()
        super().tearDown()

    def write_map_with_app(self, extra_networks=None, cidrs=None):
        networks = [{
            "name": "netA", "subnet": "10.42.0.0/16",
            "containers": [{
                "name": "app", "aliases": ["app-alias"],
                "ipv4": "10.42.0.5", "ports": ["80/tcp"],
            }],
        }]
        if extra_networks:
            networks.extend(extra_networks)
        write_netmap(self.map_path(), "127.0.0.1", self.stub.port,
                     networks=networks, cidrs=cidrs)
        self.set_map_path()

    def test_reachable_domain_name_uses_atyp3_exact_bytes(self):
        self.write_map_with_app()
        result = MOD.run_net_probe({"host": "app", "port": 80})
        self.assertFalse(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "reachable")
        self.assertEqual(self.stub.last_request["atyp"], 3)
        self.assertEqual(self.stub.last_request["addr_raw"], b"app")
        self.assertEqual(self.stub.last_request["port"], 80)

    def test_refused_rep5(self):
        self.write_map_with_app()
        self.stub.rep = 5
        result = MOD.run_net_probe({"host": "app", "port": 80})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "refused")

    def test_blocked_rep2(self):
        self.write_map_with_app()
        self.stub.rep = 2
        result = MOD.run_net_probe({"host": "app", "port": 80})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "blocked")

    def test_ipv4_inside_subnet_uses_atyp1(self):
        self.write_map_with_app()
        result = MOD.run_net_probe({"host": "10.42.3.4", "port": 443})
        self.assertFalse(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "reachable")
        self.assertEqual(self.stub.last_request["atyp"], 1)
        self.assertEqual(self.stub.last_request["addr_raw"],
                          socket.inet_aton("10.42.3.4"))

    def test_ipv4_inside_plain_cidr(self):
        self.write_map_with_app(cidrs=["192.168.9.0/24"])
        result = MOD.run_net_probe({"host": "192.168.9.7", "port": 22})
        self.assertFalse(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "reachable")

    def test_dotted_container_name_github_com_is_not_granted(self):
        write_netmap(self.map_path(), "127.0.0.1", self.stub.port, networks=[{
            "name": "netA", "subnet": "10.42.0.0/16",
            "containers": [{
                "name": "github.com", "aliases": [],
                "ipv4": "10.42.0.9", "ports": ["443/tcp"],
            }],
        }])
        self.set_map_path()
        result = MOD.run_net_probe({"host": "github.com", "port": 443})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "not_granted")
        self.assertEqual(self.stub.connections, 0)

    def test_not_granted_makes_no_connection(self):
        self.write_map_with_app()
        result = MOD.run_net_probe({"host": "unknown.example", "port": 80})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "not_granted")
        self.assertIn("cbox netaccess allow", payload["detail"])
        self.assertEqual(self.stub.connections, 0)

    def test_invalid_host_rejected(self):
        self.write_map_with_app()
        result = MOD.run_net_probe({"host": "bad_host!name", "port": 80})
        self.assertTrue(result["isError"])
        self.assertIn("host must be", result["content"][0]["text"])
        self.assertEqual(self.stub.connections, 0)

    def test_invalid_port_rejected(self):
        self.write_map_with_app()
        result = MOD.run_net_probe({"host": "app", "port": 70000})
        self.assertTrue(result["isError"])
        self.assertIn("port must be", result["content"][0]["text"])
        self.assertEqual(self.stub.connections, 0)

    def test_timeout_on_hanging_stub(self):
        self.write_map_with_app()
        self.stub.hang = True
        result = MOD.run_net_probe(
            {"host": "app", "port": 80, "timeout_sec": 1})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "timeout")

    def test_bound_addr_atyp4_parsed(self):
        self.write_map_with_app()
        self.stub.bound_atyp = 4
        self.stub.bound_addr_str = "::1"
        result = MOD.run_net_probe({"host": "app", "port": 80})
        self.assertFalse(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "reachable")
        self.assertIn("::1", payload["detail"])

    def test_bound_addr_atyp3_parsed(self):
        self.write_map_with_app()
        self.stub.bound_atyp = 3
        self.stub.bound_addr_str = "boundname.example"
        result = MOD.run_net_probe({"host": "app", "port": 80})
        self.assertFalse(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "reachable")
        self.assertIn("boundname.example", payload["detail"])

    def test_proxy_down_for_probe(self):
        dead_port = find_free_port()
        write_netmap(self.map_path(), "127.0.0.1", dead_port, networks=[{
            "name": "netA", "subnet": "10.42.0.0/16",
            "containers": [{"name": "app", "aliases": [],
                             "ipv4": "10.42.0.5", "ports": []}],
        }])
        self.set_map_path()
        result = MOD.run_net_probe({"host": "app", "port": 80})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "proxy_down")
        self.assertIn("cbox netaccess status", payload["detail"])

    def test_missing_map_reports_not_applied(self):
        self.set_map_path(os.path.join(self.tmpdir, "absent.json"))
        result = MOD.run_net_probe({"host": "app", "port": 80})
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["verdict"], "no_map")
        self.assertIn("cbox down && cbox run", payload["detail"])


class SubprocessStdioTests(EnvIsolatedTestCase):
    def setUp(self):
        super().setUp()
        self.listener = PlainListener()
        write_netmap(self.map_path(), "127.0.0.1", self.listener.port)
        self.env = dict(os.environ)
        self.env["CBOX_NETMAP_FILE"] = self.map_path()
        self.env.pop("CBOX_SOCKS_PROXY", None)

    def tearDown(self):
        self.listener.stop()
        super().tearDown()

    def _run(self, messages):
        proc = subprocess.run(
            [sys.executable, str(ROOT / "etc" / "mcp" / "cbox_net_mcp.py")],
            input="".join(json.dumps(m) + "\n" for m in messages).encode(),
            capture_output=True,
            env=self.env,
            timeout=15,
        )
        lines = [l for l in proc.stdout.decode().splitlines() if l.strip()]
        return proc, [json.loads(l) for l in lines]

    def test_initialize_tools_list_and_call(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2024-11-05"}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": {"name": "net_map", "arguments": {}}},
        ]
        proc, replies = self._run(messages)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"],
                          "cbox-net")
        tool_names = sorted(t["name"] for t in replies[1]["result"]["tools"])
        self.assertEqual(tool_names, ["net_map", "net_probe"])
        self.assertFalse(replies[2]["result"]["isError"])
        payload = json.loads(replies[2]["result"]["content"][0]["text"])
        self.assertEqual(payload["status"], "ok")

    def test_unknown_tool_name_is_protocol_error(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "does-not-exist", "arguments": {}}},
        ]
        proc, replies = self._run(messages)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(replies[0]["error"]["code"], -32602)

    def test_ping_and_unknown_method(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "ping"},
            {"jsonrpc": "2.0", "id": 2, "method": "no-such-method"},
        ]
        proc, replies = self._run(messages)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(replies[0]["result"], {})
        self.assertEqual(replies[1]["error"]["code"], -32601)

    def test_parse_error(self):
        proc = subprocess.run(
            [sys.executable, str(ROOT / "etc" / "mcp" / "cbox_net_mcp.py")],
            input=b"not json\n",
            capture_output=True,
            env=self.env,
            timeout=15,
        )
        lines = [l for l in proc.stdout.decode().splitlines() if l.strip()]
        replies = [json.loads(l) for l in lines]
        self.assertEqual(replies[0]["error"]["code"], -32700)

    def test_non_object_message_does_not_crash(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "ping"},
        ]
        proc = subprocess.run(
            [sys.executable, str(ROOT / "etc" / "mcp" / "cbox_net_mcp.py")],
            input=b"[1]\n" + b"".join(
                (json.dumps(m) + "\n").encode() for m in messages),
            capture_output=True,
            env=self.env,
            timeout=15,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        lines = [l for l in proc.stdout.decode().splitlines() if l.strip()]
        replies = [json.loads(l) for l in lines]
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]["result"], {})


if __name__ == "__main__":
    unittest.main()
