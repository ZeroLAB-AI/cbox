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
        }
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

    def container(self):
        return {
            "Config": {"Labels": {"com.docker.compose.project": self.project}},
            "NetworkSettings": {"Networks": self.endpoints},
        }

    def __call__(self, docker_bin, args, timeout=15):
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

    def test_explicit_unsupported_network_fails_closed(self):
        with self.assertRaises(PermissionError):
            MOD.apply(self.args(["host"]))

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


if __name__ == "__main__":
    unittest.main()
