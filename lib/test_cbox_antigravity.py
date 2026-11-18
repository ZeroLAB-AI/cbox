import asyncio
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import cbox_antigravity as agy
import cbox_antigravity_runtime as runtime
import cbox_isolation as isolation
from cbox_delegate_relay import Caller, MAX_REQUEST_BYTES, SessionRelay, Turn
from cbox_peer_mcp import ENGINES, PeerMcp, serve


INSTALL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(INSTALL / "etc/hooks"))
sys.path.insert(0, str(INSTALL / "etc/mcp"))
import antigravity_delegate
import antigravity_guard


class OfflineReleaseTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.store = self.root / "store"

    def release(self, version, content, *, member="antigravity"):
        artifact = self.root / (version + ".tar.gz")
        with tarfile.open(artifact, "w:gz") as archive:
            entry = tarfile.TarInfo(member)
            entry.size = len(content)
            archive.addfile(entry, io.BytesIO(content))
        pin = self.root / (version + ".json")
        pin.write_text(json.dumps({"version": version, "url": "https://example.test/" + artifact.name,
                                   "sha512": hashlib.sha512(artifact.read_bytes()).hexdigest()}))
        return pin, artifact

    def test_verified_upgrade_rollback_and_offline_bind(self):
        pin, artifact = self.release("1.2.3", b"\x7fELFold")
        output = subprocess.check_output(
            ["bash", str(INSTALL / "cbox"), "isolation", "agy-release", "prepare", "--store", str(self.store),
             "--pin", str(pin), "--artifact", str(artifact)],
            text=True,
            timeout=10,
        )
        first = Path(output.strip())
        second = agy.prepare_release(self.store, *self.release("1.2.4", b"\x7fELFnew"))
        self.assertEqual(agy.selection(self.store), {"current": second.name, "previous": first.name})
        repo = self.root / "workspace"
        repo.mkdir()
        (repo / ".git").mkdir()
        plan = isolation.render(str(repo), "local-cbox:test", "probe", ["claude", "antigravity"],
                                1000, 1000, runtime=True, release=second)
        self.assertEqual(plan["services"]["antigravity"]["volumes"][-1],
                         isolation.readonly_bind(second / "agy", "/opt/antigravity/agy"))
        self.assertFalse(any(mount["source"] == str(second / "agy")
                             for mount in plan["services"]["claude"]["volumes"]))
        self.assertEqual(agy.rollback(self.store), first)
        self.assertEqual(agy.selection(self.store), {"current": first.name, "previous": second.name})

    def test_bad_upgrade_preserves_selection_and_detects_tampering(self):
        initial = agy.prepare_release(self.store, *self.release("1.2.3", b"\x7fELFold"))
        pin, artifact = self.release("1.2.4", b"\x7fELFnew")
        artifact.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "SHA512 mismatch"):
            agy.prepare_release(self.store, pin, artifact)
        with self.assertRaisesRegex(ValueError, "regular antigravity"):
            agy.prepare_release(self.store, *self.release("1.2.5", b"\x7fELFunexpected", member="../antigravity"))
        self.assertEqual(agy.selection(self.store), {"current": initial.name, "previous": None})
        binary = initial / "agy"
        binary.chmod(0o755)
        binary.write_bytes(b"\x7fELFtampered")
        with self.assertRaisesRegex(ValueError, "binary digest mismatch"):
            agy.verify_release(initial)

    def test_host_topology_isolates_credential_volume_and_online_gateway(self):
        release = agy.prepare_release(self.store, *self.release("1.2.3", b"\x7fELFfixture"))
        root = self.root / "repo with spaces"
        root.mkdir()
        (root / ".git").mkdir()
        provenance = agy.read_json(release / "provenance.json")
        doc = runtime.validate_config({"schema": 1, "engine_image": "sha256:" + "a" * 64,
                                       "proxy_image": "sha256:" + "b" * 64, "release": str(release),
                                       "binary_sha256": provenance["binary_sha256"],
                                       "domains": ["api.example.test", "login.example.test"]})
        with self.assertRaisesRegex(ValueError, "exact DNS names"):
            runtime.validate_config({**doc, "domains": ["*.example.test"]})
        offline = runtime.compose_document(root, doc, self.root, "probe", 1000, 1000)
        self.assertNotIn("networks", offline)
        self.assertEqual(offline["services"]["antigravity"]["network_mode"], "none")
        self.assertFalse(any(m.get("source") == str(root) for m in offline["services"]["antigravity"]["volumes"]))
        online = runtime.compose_document(root, doc, self.root, "acp", 1000, 1000)
        worker = online["services"]["antigravity"]
        gateway = online["services"]["gateway"]
        self.assertEqual(worker["networks"], ["client"])
        client = online["networks"]["client"]
        self.assertTrue(client["internal"])
        self.assertFalse(client["enable_ipv6"])
        self.assertEqual(client["driver_opts"]["com.docker.network.bridge.gateway_mode_ipv4"], "isolated")
        self.assertEqual(worker["dns"], ["127.0.0.1"])
        self.assertEqual(worker["working_dir"], str(root))
        self.assertEqual(gateway["networks"], ["client", "external-egress"])
        self.assertTrue(all(m["read_only"] for m in gateway["volumes"]))
        self.assertEqual([m["source"] for m in worker["volumes"] if m["type"] == "volume"], ["antigravity-home"])
        self.assertIn("FilterDefaultDeny Yes", (self.root / "tinyproxy.conf").read_text())
        self.assertEqual((self.root / "domains").read_text(), "^api[.]example[.]test$\n^login[.]example[.]test$\n")
        self.assertNotIn("ports", gateway)

    def test_main_entrypoints_are_disabled_before_workspace_configuration(self):
        workspace = self.root / "workspace"
        home = self.root / "home"
        workspace.mkdir()
        home.mkdir()
        env = {"HOME": str(home), "PATH": os.environ["PATH"]}
        subprocess.run(["git", "init", "-q", str(workspace)], env=env, check=True)
        for args in (["run", "antigravity", "--effort", "low"], ["acp", "antigravity"]):
            with self.subTest(args=args):
                result = subprocess.run(["bash", str(INSTALL / "cbox"), *args],
                                        cwd=workspace, env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("Antigravity is disabled for this workspace", result.stderr)
        self.assertFalse((home / ".config/cbox/antigravity").exists())

    def test_host_launch_requires_matching_offline_probe_before_using_vendor_network(self):
        directory = self.root / "config"
        directory.mkdir(mode=0o700)
        root = self.root / "workspace"
        doc = {"engine_image": "fixture"}
        with patch.object(runtime, "config", return_value=doc), \
                patch.object(runtime, "compose_document", return_value={"name": "fixture"}), \
                patch.object(runtime, "compose_call", return_value=0) as docker, \
                patch.object(runtime.subprocess, "run"):
            with self.assertRaisesRegex(ValueError, "agy probe"):
                runtime.launch(root, directory, "acp", [])
            docker.assert_not_called()
            self.assertEqual(runtime.launch(root, directory, "probe", []), 0)
            self.assertEqual(docker.call_args_list[0].args[0][-2:], ["antigravity", "--version"])
            self.assertEqual(docker.call_args_list[1].args[0][-3:], ["antigravity", "acp", "--help"])
            self.assertEqual(runtime.launch(root, directory, "acp", []), 0)
            self.assertEqual(docker.call_args.args[0][-4:], ["--rm", "-T", "antigravity", "acp"])
        with self.assertRaisesRegex(ValueError, "agy probe"):
            runtime.require_probe(directory, {**doc, "engine_image": "changed"})

    def test_vendor_hook_payload_translates_and_guards_workspace(self):
        inside = str(self.root / "src")
        tool = {"toolCall": {"name": "run_command", "args": {"CommandLine": "git status", "Cwd": inside}}}
        with patch.object(antigravity_guard, "WORKSPACE", self.root):
            self.assertEqual(antigravity_guard.pre_tool(tool)["decision"], "allow")
            tool["toolCall"]["args"]["Cwd"] = str(self.root / "..")
            self.assertEqual(antigravity_guard.pre_tool(tool)["decision"], "deny")
            (self.root / "outside").symlink_to("/etc", target_is_directory=True)
            tool["toolCall"] = {"name": "view_file", "args": {"AbsolutePath": str(self.root / "outside/passwd")}}
            self.assertEqual(antigravity_guard.pre_tool(tool)["decision"], "deny")


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.workspace = Path(tmp.name).resolve()
        self.turns = []
        self.started = asyncio.Event()
        self.finished = asyncio.Event()

        async def target(turn):
            self.turns.append(turn)
            if turn.prompt == "wait":
                self.started.set()
                try:
                    await asyncio.Future()
                finally:
                    self.finished.set()
            return {"caller": turn.caller, "model": turn.model}

        self.relay = SessionRelay(self.workspace, {"antigravity": target})
        self.token = self.relay.issue_main_capability(Caller("claude", frozenset({"antigravity"}), write=True))
        self.server = await asyncio.start_unix_server(self.relay.handle, path=self.workspace / "relay.sock")
        self.addAsyncCleanup(self.server.wait_closed)
        self.addCleanup(self.server.close)

    async def connect(self, **overrides):
        request = {"id": "task", "version": 1, "token": self.token, "target": "antigravity",
                   "cwd": str(self.workspace), "prompt": "probe", "model": "model-a", "effort": "low", "mode": "write"}
        request.update(overrides)
        reader, writer = await asyncio.open_unix_connection(self.workspace / "relay.sock")
        writer.write(json.dumps(request).encode() + b"\n")
        await writer.drain()
        return reader, writer

    async def call(self, **overrides):
        reader, writer = await self.connect(**overrides)
        try:
            return json.loads(await asyncio.wait_for(reader.readline(), timeout=2))
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_identity_scope_and_replay(self):
        self.assertIn("capability", (await self.call(token="A" * 43))["error"])
        self.assertIn("envelope", (await self.call(caller="antigravity", depth=0))["error"])
        self.assertIn("workspace", (await self.call(cwd=str(self.workspace.parent)))["error"])
        self.assertEqual((await self.call())["result"], {"caller": "claude", "model": "model-a"})
        self.assertIn("duplicate", (await self.call())["error"])
        self.assertEqual(len(self.turns), 1)

    async def test_disconnect_releases_write_lease(self):
        _, writer = await self.connect(prompt="wait")
        await asyncio.wait_for(self.started.wait(), timeout=2)
        self.assertTrue(self.relay.writes.locked())
        writer.close()
        await writer.wait_closed()
        await asyncio.wait_for(self.finished.wait(), timeout=2)
        self.assertIn("result", await self.call(id="different-task"))


class StreamTests(unittest.IsolatedAsyncioTestCase):
    async def test_vendor_stream_success_and_argument_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            executable = workspace / "agy"
            executable.write_text(
                "#!/usr/bin/python3\nimport json, sys\n"
                "assert json.load(sys.stdin)['message']['content'] == 'test prompt'\n"
                "assert sys.argv[1:] == ['--model', 'model-a', '--effort', 'low', "
                "'--input-format', 'stream-json', '--output-format', 'stream-json']\n"
                "print(json.dumps({'event':'init','conversation_id':'test-id'}))\n"
                "print(json.dumps({'event':'step_update','step_update':{'step_index':1}}))\n"
                "print(json.dumps({'event':'result','result':{'conversation_id':'test-id',"
                "'status':'SUCCESS','response':'answer'}}))\n"
            )
            executable.chmod(0o755)
            turn = Turn("claude", "antigravity", workspace, "test prompt", "model-a", "low", False)
            with self.assertRaisesRegex(ValueError, "unsupported"):
                await antigravity_delegate.run_turn(executable, turn, {}, home=workspace)
            result = await antigravity_delegate.run_turn(executable, turn, {"model-a": {"low"}}, home=workspace)
            self.assertEqual(result, {"response": "answer", "conversation_id": "test-id", "model": "model-a", "effort": "low"})

    async def test_inconsistent_vendor_result_is_rejected(self):
        stream = antigravity_delegate.TurnStream()
        stream.accept(b'{"event":"init","conversation_id":"one"}\n')
        with self.assertRaisesRegex(ValueError, "inconsistent"):
            stream.accept(b'{"event":"result","result":{"conversation_id":"another"}}\n')

    async def test_cancellation_stops_the_owned_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            executable = workspace / "agy"
            executable.write_text(
                "#!/usr/bin/python3\nimport os, sys, time\n"
                "sys.stdin.readline()\n"
                "print('{\"event\":\"init\",\"conversation_id\":\"wait-id\"}', flush=True)\n"
                "open('pid', 'w').write(str(os.getpid()))\n"
                "time.sleep(30)\n"
            )
            executable.chmod(0o755)
            turn = Turn("claude", "antigravity", workspace, "wait", "model-a", "low", False)
            started = asyncio.Event()

            async def progress(_):
                started.set()

            task = asyncio.create_task(antigravity_delegate.run_turn(
                executable, turn, {"model-a": {"low"}}, home=workspace, progress=progress,
            ))
            try:
                await asyncio.wait_for(started.wait(), timeout=2)
                async with asyncio.timeout(2):
                    while not (workspace / "pid").exists() or not (workspace / "pid").stat().st_size:
                        await asyncio.sleep(0.01)
                pid = int((workspace / "pid").read_text())
            finally:
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await asyncio.wait_for(task, timeout=2)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)


class PeerMatrixTests(unittest.IsolatedAsyncioTestCase):
    async def test_oversized_frame_keeps_existing_turn_and_next_request_alive(self):
        entered = asyncio.Event()
        unblock = asyncio.Event()

        class Proxy:
            async def call(self, params):
                entered.set()
                await unblock.wait()
                return {"text": "completed"}

            def list_tools(self):
                return {"tools": []}

        reader = asyncio.StreamReader(limit=MAX_REQUEST_BYTES)
        replies = asyncio.Queue()
        wire = asyncio.create_task(serve(Proxy(), reader, replies.put_nowait))

        async def receive():
            return await asyncio.wait_for(replies.get(), timeout=2)

        try:
            reader.feed_data(b'{"jsonrpc":"2.0","method":"tools/call","id":1}\n')
            await asyncio.wait_for(entered.wait(), timeout=2)
            reader.feed_data(b"a" * (MAX_REQUEST_BYTES + 1))
            await asyncio.sleep(0)
            reader.feed_data(b'b\n{"jsonrpc":"2.0","method":"tools/list","id":2}\n')
            self.assertEqual((await receive())["error"]["code"], -32600)
            self.assertEqual((await receive())["id"], 2)
            unblock.set()
            self.assertEqual((await receive())["result"], {"text": "completed"})
        finally:
            reader.feed_eof()
            await wire

    async def test_every_main_calls_all_three_peers_over_mcp(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory).resolve()
            socket = workspace / "relay.sock"
            catalog = {engine: {engine + "/model:1": ["low", "xhigh"]} for engine in ENGINES}

            async def target(turn):
                return {"caller": turn.caller, "target": turn.target, "model": turn.model,
                        "effort": turn.effort, "size": turn.size}

            relay = SessionRelay(workspace, dict.fromkeys(ENGINES, target))
            server = await asyncio.start_unix_server(relay.handle, path=socket)
            async with server:
                for caller in ENGINES:
                    peers = set(ENGINES) - {caller}
                    token = relay.issue_main_capability(Caller(caller, frozenset(peers)))
                    proxy = PeerMcp(caller, catalog, socket, token)
                    reader = asyncio.StreamReader()
                    replies = asyncio.Queue()
                    wire = asyncio.create_task(serve(proxy, reader, replies.put_nowait))
                    try:
                        def request(method, request_id, params=None):
                            message = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}
                            reader.feed_data(json.dumps(message).encode() + b"\n")

                        async def reply():
                            result = await asyncio.wait_for(replies.get(), timeout=2)
                            self.assertNotIn(token, json.dumps(result))
                            return result["result"]

                        request("initialize", 0, {"protocolVersion": "2025-06-18"})
                        self.assertEqual((await reply())["protocolVersion"], "2025-06-18")
                        request("tools/list", 1)
                        self.assertEqual({tool["name"] for tool in (await reply())["tools"]}, {"ask-" + name for name in peers})
                        for request_id, peer in enumerate(sorted(peers), start=2):
                            args = {"cwd": str(workspace), "prompt": "read", "mode": "read",
                                    "model": peer + "/model:1", "effort": "low"}
                            if peer == "hermes":
                                args["size"] = "small"
                            request("tools/call", request_id, {"name": "ask-" + peer, "arguments": args})
                        verified = set()
                        for _ in peers:
                            result = await reply()
                            self.assertFalse(result["isError"])
                            data = json.loads(result["content"][0]["text"])
                            self.assertEqual(data, {"caller": caller, "target": data["target"],
                                                    "model": data["target"] + "/model:1", "effort": "low",
                                                    "size": "small" if data["target"] == "hermes" else None})
                            verified.add(data["target"])
                        self.assertEqual(verified, peers)
                        args["effort"] = "wrong"
                        request("tools/call", 10, {"name": "ask-" + peer, "arguments": args})
                        self.assertTrue((await reply())["isError"])
                    finally:
                        reader.feed_eof()
                        await wire


if __name__ == "__main__":
    unittest.main()
