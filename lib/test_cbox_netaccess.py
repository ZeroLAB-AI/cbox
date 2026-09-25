#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
import tempfile
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("cbox_netaccess", os.path.join(HERE, "cbox_netaccess.py"))
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class FakeDocker:
    def __init__(self):
        self.project = "cbox-p1"
        self.container_id = "a" * 64
        self.endpoints = {
            "cbox-p1_internal": {"IPAddress": "172.20.0.2"},
            "cbox-p1_egress": {"IPAddress": "172.21.0.2"},
        }
        self.docs = {
            "cbox-p1_internal": self.network("bridge", "172.20.0.0/24", "internal"),
            "cbox-p1_egress": self.network("bridge", "172.21.0.0/24", "egress"),
            "project_a": self.network("bridge", "10.10.0.0/24"),
            "project_b": self.network("bridge", "10.11.0.0/24"),
            "host": self.network("host", "192.168.0.0/24"),
            "cbox-ollama-u1000-global": self.ollama_network("10.55.0.0/24"),
            "cbox-ollama-u1000-p1": self.ollama_network("10.56.0.0/24"),
        }
        self.other_containers = {}
        self.connected = []
        self.disconnected = []

    def network(self, driver, subnet, kind=""):
        labels = {}
        if kind:
            labels = {
                "com.docker.compose.project": self.project,
                "com.docker.compose.network": kind,
            }
        return {"Driver": driver, "Labels": labels, "IPAM": {"Config": [{"Subnet": subnet}]}}

    def ollama_network(self, subnet):
        labels = {"cbox.kind": "infra", "cbox.component": "ollama-net"}
        return {"Driver": "bridge", "Labels": labels, "IPAM": {"Config": [{"Subnet": subnet}]}}

    def container(self):
        return {
            "Config": {"Labels": {"com.docker.compose.project": self.project}},
            "NetworkSettings": {"Networks": self.endpoints},
        }

    def add_container_to_network(self, network, cid, name, ipv4, aliases=None, dns_names=None, ports=None):
        containers = self.docs[network].setdefault("Containers", {})
        containers[cid] = {"Name": name, "IPv4Address": ipv4 + "/24"}
        self.other_containers[cid] = {
            "Id": cid,
            "Config": {"ExposedPorts": {p: {} for p in (ports or [])}},
            "NetworkSettings": {
                "Networks": {
                    network: {
                        "Aliases": aliases or [],
                        "DNSNames": dns_names or [],
                    }
                }
            },
        }

    def __call__(self, docker_bin, args, timeout=15):
        if args[:1] == ["inspect"] and len(args) > 1 and args[1] != self.container_id:
            ids = args[1:]
            result = [self.other_containers[cid] for cid in ids if cid in self.other_containers]
            return json.dumps(result)
        if args == ["network", "ls", "--format", "{{.Name}}"]:
            return "\n".join(self.docs) + "\n"
        if args[:2] == ["network", "inspect"]:
            name = args[2]
            if name not in self.docs:
                raise RuntimeError("not found")
            return json.dumps([self.docs[name]])
        if args[:1] == ["inspect"]:
            return json.dumps([self.container()])
        if args[:2] == ["network", "connect"]:
            name = args[2]
            subnet = self.docs[name]["IPAM"]["Config"][0]["Subnet"]
            base = subnet.split(".")[:3]
            self.endpoints[name] = {"IPAddress": ".".join(base + ["2"])}
            self.connected.append(name)
            return ""
        if args[:3] == ["network", "disconnect", "-f"]:
            name = args[3]
            self.endpoints.pop(name, None)
            self.disconnected.append(name)
            return ""
        raise AssertionError(args)


class NetaccessTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeDocker()
        self.original_run = MOD.run
        MOD.run = self.fake
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        MOD.run = self.original_run
        self.tmp.cleanup()

    def args(self, networks, cidrs=None, scope="list"):
        return argparse.Namespace(
            docker_bin="docker",
            container="a" * 64,
            state_dir=self.tmp.name,
            scope=scope,
            network=networks,
            cidr=cidrs or [],
        )

    def test_apply_connects_selected_and_renders_routes(self):
        result = MOD.apply(self.args(["project_a"], ["10.42.0.0/16"]))
        self.assertEqual(result["internalIp"], "172.20.0.2")
        self.assertEqual(result["internalCidr"], "172.20.0.0/24")
        self.assertEqual(self.fake.connected, ["project_a"])
        self.assertEqual(result["targets"][0], {
            "network": "project_a",
            "externalIp": "10.10.0.2",
            "cidr": "10.10.0.0/24",
        })
        self.assertEqual(result["targets"][1]["externalIp"], "172.21.0.2")
        self.assertEqual(result["targets"][1]["cidr"], "10.42.0.0/16")

    def test_scope_change_disconnects_stale_network(self):
        MOD.apply(self.args(["project_a"]))
        MOD.apply(self.args(["project_b"]))
        self.assertEqual(self.fake.disconnected, ["project_a"])
        self.assertEqual(self.fake.connected, ["project_a", "project_b"])

    def test_all_skips_infrastructure_and_unsupported_networks(self):
        result = MOD.apply(self.args([], scope="all"))
        self.assertEqual(result["appliedNetworks"], ["project_a", "project_b"])
        reasons = {item["network"]: item["reason"] for item in result["skipped"]}
        self.assertIn("cbox-p1_internal", reasons)
        self.assertIn("cbox-p1_egress", reasons)
        self.assertIn("host", reasons)

    def test_all_rejects_per_scope_ollama_networks(self):
        result = MOD.apply(self.args([], scope="all"))
        self.assertNotIn("cbox-ollama-u1000-global", result["appliedNetworks"])
        self.assertNotIn("cbox-ollama-u1000-p1", result["appliedNetworks"])
        reasons = {item["network"]: item["reason"] for item in result["skipped"]}
        self.assertIn("cbox-ollama-u1000-global", reasons)
        self.assertIn("cbox-ollama-u1000-p1", reasons)
        for name in ("cbox-ollama-u1000-global", "cbox-ollama-u1000-p1"):
            self.assertIn("cbox infrastructure", reasons[name])
        self.assertEqual(self.fake.connected, ["project_a", "project_b"])

    def test_explicit_ollama_network_fails_closed(self):
        with self.assertRaises(PermissionError):
            MOD.apply(self.args(["cbox-ollama-u1000-global"]))

    def test_explicit_unsupported_network_fails_closed(self):
        with self.assertRaises(PermissionError):
            MOD.apply(self.args(["host"]))

    def test_scope_list_absent_network_is_skipped_not_fatal(self):
        result = MOD.apply(self.args(["project_a", "markiza-cloud-network"]))
        self.assertEqual(result["appliedNetworks"], ["project_a"])
        self.assertEqual(self.fake.connected, ["project_a"])
        skipped = {item["network"]: item for item in result["skipped"]}
        self.assertIn("markiza-cloud-network", skipped)
        self.assertTrue(skipped["markiza-cloud-network"]["requested"])
        self.assertIn("not found", skipped["markiza-cloud-network"]["reason"])

    def test_scope_list_forbidden_network_still_raises(self):
        with self.assertRaises(PermissionError):
            MOD.apply(self.args(["project_a", "host"]))
        self.assertEqual(self.fake.connected, [])

    def test_scope_all_skipped_shape_is_stable(self):
        result = MOD.apply(self.args([], scope="all"))
        for item in result["skipped"]:
            self.assertIn("network", item)
            self.assertIn("reason", item)
            self.assertIn("requested", item)
            self.assertFalse(item["requested"])

    def test_sanitize_reason_caps_length_and_strips_control_chars(self):
        raw = "boom\x1b[31m" + ("x" * 200)
        cleaned = MOD.sanitize_reason(raw)
        self.assertLessEqual(len(cleaned), 123)
        self.assertTrue(all(32 <= ord(ch) < 127 for ch in cleaned))
        self.assertTrue(cleaned.endswith("..."))

    def test_symlink_state_dir_is_rejected(self):
        target = os.path.join(self.tmp.name, "target")
        link = os.path.join(self.tmp.name, "link")
        os.mkdir(target)
        os.symlink(target, link)
        args = self.args(["project_a"])
        args.state_dir = link
        with self.assertRaises(PermissionError):
            MOD.apply(args)

    def test_failed_apply_rolls_back_new_attachment(self):
        self.fake.docs["project_a"]["IPAM"] = {"Config": [{"Subnet": "10.10.0.0/24"}]}
        original = self.fake.__call__

        def broken(docker_bin, args, timeout=15):
            value = original(docker_bin, args, timeout)
            if args[:1] == ["inspect"] and "project_a" in self.fake.endpoints:
                self.fake.endpoints["project_a"] = {"IPAddress": ""}
                value = json.dumps([self.fake.container()])
            return value

        MOD.run = broken
        with self.assertRaises(RuntimeError):
            MOD.apply(self.args(["project_a"]))
        self.assertEqual(self.fake.connected, ["project_a"])
        self.assertEqual(self.fake.disconnected, ["project_a"])

    def test_apply_writes_netmap_with_containers_aliases_and_ports(self):
        cid = "b" * 64
        self.fake.add_container_to_network(
            "project_a", cid, "webapp", "10.10.0.5",
            aliases=["webapp", cid[:12]],
            dns_names=["webapp", cid[:12], "webapp.project_a"],
            ports=["80/tcp"],
        )
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        MOD.apply(args)
        with open(netmap_out, encoding="ascii") as fh:
            netmap = json.load(fh)
        self.assertEqual(netmap["version"], 1)
        self.assertEqual(netmap["scope"], "list")
        self.assertEqual(netmap["proxy"], {
            "url": "socks5h://cbox-proxy-internal:1080",
            "host": "cbox-proxy-internal",
            "port": 1080,
        })
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        self.assertEqual(net["subnet"], "10.10.0.0/24")
        self.assertEqual(len(net["containers"]), 1)
        entry = net["containers"][0]
        self.assertEqual(entry["name"], "webapp")
        self.assertEqual(entry["ipv4"], "10.10.0.5")
        self.assertEqual(entry["ports"], ["80/tcp"])
        self.assertTrue(entry["name_routable"])
        self.assertIn("webapp", entry["aliases"])
        self.assertNotIn("webapp.project_a", entry["aliases"])
        self.assertNotIn(cid[:12], entry["aliases"])
        self.assertEqual(entry["aliases"].count("webapp"), 1)
        self.assertEqual(net["dropped"], 1)

    def test_injection_shaped_alias_dropped(self):
        cid = "c" * 64
        self.fake.add_container_to_network(
            "project_a", cid, "webapp", "10.10.0.6",
            aliases=["webapp", "evil$(whoami)", "evil;rm -rf /", "evil name"],
            ports=["80/tcp"],
        )
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        MOD.apply(args)
        with open(netmap_out, encoding="ascii") as fh:
            netmap = json.load(fh)
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        entry = net["containers"][0]
        self.assertEqual(entry["aliases"], ["webapp"])
        self.assertEqual(net["dropped"], 3)

    def test_injection_shaped_port_dropped(self):
        cid = "d" * 64
        self.fake.add_container_to_network(
            "project_a", cid, "webapp", "10.10.0.7",
            aliases=["webapp"],
            ports=["80/tcp", "80/tcp; rm -rf /", "not-a-port", "70000/tcp", "0/tcp"],
        )
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        MOD.apply(args)
        with open(netmap_out, encoding="ascii") as fh:
            netmap = json.load(fh)
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        entry = net["containers"][0]
        self.assertEqual(entry["ports"], ["80/tcp"])
        self.assertEqual(net["dropped"], 4)

    def test_dotted_alias_always_dropped(self):
        cid = "e" * 64
        self.fake.add_container_to_network(
            "project_a", cid, "webapp", "10.10.0.8",
            aliases=["webapp", "github.com", "webapp"],
        )
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        MOD.apply(args)
        with open(netmap_out, encoding="ascii") as fh:
            netmap = json.load(fh)
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        entry = net["containers"][0]
        self.assertEqual(entry["aliases"], ["webapp"])
        self.assertEqual(net["dropped"], 1)

    def test_dotted_container_name_is_not_routable(self):
        cid = "1" * 64
        self.fake.add_container_to_network(
            "project_a", cid, "github.com", "10.10.0.10",
            aliases=["github.com", "webapp"],
        )
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        MOD.apply(args)
        with open(netmap_out, encoding="ascii") as fh:
            netmap = json.load(fh)
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        entry = net["containers"][0]
        self.assertEqual(entry["name"], "github.com")
        self.assertEqual(entry["ipv4"], "10.10.0.10")
        self.assertFalse(entry["name_routable"])
        self.assertNotIn("github.com", entry["aliases"])
        self.assertEqual(entry["aliases"], ["webapp"])

    def test_alias_and_port_caps_enforced_per_container(self):
        cid = "f" * 64
        aliases = ["a-%d" % i for i in range(20)]
        ports = ["%d/tcp" % (1000 + i) for i in range(40)]
        self.fake.add_container_to_network(
            "project_a", cid, "webapp", "10.10.0.9",
            aliases=aliases, ports=ports,
        )
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        MOD.apply(args)
        with open(netmap_out, encoding="ascii") as fh:
            netmap = json.load(fh)
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        entry = net["containers"][0]
        self.assertEqual(len(entry["aliases"]), 16)
        self.assertEqual(len(entry["ports"]), 32)
        self.assertEqual(net["dropped"], 4 + 8)

    def test_container_cap_enforced_per_network(self):
        for i in range(520):
            cid = ("%040x" % i) + "0" * 24
            self.fake.add_container_to_network(
                "project_a", cid, "webapp-%d" % i, "10.10.1.%d" % (i % 250),
            )
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        MOD.apply(args)
        with open(netmap_out, encoding="ascii") as fh:
            netmap = json.load(fh)
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        self.assertEqual(len(net["containers"]), 512)
        self.assertEqual(net["dropped"], 8)

    def test_apply_netmap_excludes_the_proxy_container_itself(self):
        self.fake.add_container_to_network(
            "project_a", self.fake.container_id, "cbox-proxy", "10.10.0.2",
        )
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        MOD.apply(args)
        with open(netmap_out, encoding="ascii") as fh:
            netmap = json.load(fh)
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        self.assertEqual(net["containers"], [])

    def test_apply_without_netmap_out_writes_nothing(self):
        args = self.args(["project_a"])
        MOD.apply(args)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "netmap")))

    def test_netmap_only_makes_no_connect_or_disconnect_calls(self):
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        netmap = MOD.netmap_only(args)
        self.assertEqual(self.fake.connected, [])
        self.assertEqual(self.fake.disconnected, [])
        self.assertEqual(netmap["networks"], [])
        skipped = {item["network"]: item["reason"] for item in netmap["skipped"]}
        self.assertIn("project_a", skipped)
        self.assertIn("not attached", skipped["project_a"])

    def test_netmap_only_reports_already_attached_networks_without_reconnecting(self):
        cid = "c" * 64
        self.fake.add_container_to_network("project_a", cid, "webapp", "10.10.0.5", ports=["80/tcp"])
        apply_args = self.args(["project_a"])
        MOD.apply(apply_args)
        self.assertEqual(self.fake.connected, ["project_a"])
        args = self.args(["project_a"])
        netmap_out = os.path.join(self.tmp.name, "netmap", "netmap.json")
        args.netmap_out = netmap_out
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        netmap = MOD.netmap_only(args)
        self.assertEqual(self.fake.connected, ["project_a"])
        self.assertEqual(self.fake.disconnected, [])
        net = next(n for n in netmap["networks"] if n["name"] == "project_a")
        self.assertEqual(net["containers"][0]["name"], "webapp")

    def test_valid_hostname_rejects_trailing_newline(self):
        self.assertFalse(MOD.valid_hostname("webapp\n"))
        self.assertTrue(MOD.valid_hostname("webapp"))

    def test_valid_port_spec_rejects_trailing_newline(self):
        self.assertFalse(MOD.valid_port_spec("80/tcp\n"))
        self.assertTrue(MOD.valid_port_spec("80/tcp"))

    def test_netmap_dir_symlink_is_rejected(self):
        target = os.path.join(self.tmp.name, "netmap-target")
        link = os.path.join(self.tmp.name, "netmap-link")
        os.mkdir(target)
        os.symlink(target, link)
        args = self.args(["project_a"])
        args.netmap_out = os.path.join(link, "netmap.json")
        args.proxy_url = "socks5h://cbox-proxy-internal:1080"
        with self.assertRaises(PermissionError):
            MOD.apply(args)


if __name__ == "__main__":
    unittest.main()
