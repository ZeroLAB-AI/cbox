import argparse
import asyncio
import json
from pathlib import Path
import sys
import uuid

from cbox_delegate_relay import CAPABILITY, IDENTIFIER, MAX_REPLY_BYTES, MAX_REQUEST_BYTES, MODEL_ID


ENGINES = ("claude", "codex", "hermes", "antigravity")
PROTOCOLS = ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")
MAX_CONCURRENT_CALLS = 16


def peer_models(engine, catalog):
    if engine not in ENGINES or not isinstance(catalog, dict) or set(catalog) - set(ENGINES):
        raise ValueError("invalid engine catalog")
    tools = {}
    for peer, models in catalog.items():
        if peer == engine:
            continue
        if not isinstance(models, dict) or not models:
            raise ValueError("peer models must be a nonempty mapping")
        for model, levels in models.items():
            if not isinstance(model, str) or not MODEL_ID.fullmatch(model) or not isinstance(levels, list) or not levels or not all(
                isinstance(level, str) and IDENTIFIER.fullmatch(level) for level in levels
            ):
                raise ValueError("invalid peer model or effort catalog")
        tools["ask-" + peer] = models
    return tools


class PeerMcp:
    def __init__(self, engine, catalog, socket, token):
        if not CAPABILITY.fullmatch(token):
            raise ValueError("invalid capability file")
        self.peers = peer_models(engine, catalog)
        self.socket = socket
        self.token = token

    def list_tools(self):
        tools = []
        for tool, models in sorted(self.peers.items()):
            properties = {
                "model": {"type": "string", "enum": sorted(models),
                          "description": "Efforts by model: " + json.dumps(models, sort_keys=True)},
                "effort": {"type": "string", "enum": sorted({level for levels in models.values() for level in levels})},
                "cwd": {"type": "string", "description": "Absolute workspace directory in the delegate namespace"},
                "prompt": {"type": "string"},
                "mode": {"type": "string", "enum": ["read", "write"]},
            }
            required = sorted(properties)
            if tool == "ask-hermes":
                properties["size"] = {"type": "string", "enum": ["full", "small"], "default": "full"}
            tools.append({"name": tool, "description": "Run one bounded peer turn",
                          "inputSchema": {"type": "object", "required": required,
                                          "properties": properties, "additionalProperties": False}})
        return {"tools": tools}

    async def call(self, params):
        tool = params.get("name")
        args = params.get("arguments")
        models = self.peers.get(tool) if isinstance(tool, str) else None
        required = {"prompt", "cwd", "model", "effort", "mode"}
        optional = {"size"} if tool == "ask-hermes" else set()
        if (models is None or not isinstance(args, dict) or not required <= args.keys() <= required | optional
                or not all(isinstance(value, str) for value in args.values())
                or args["mode"] not in ("read", "write")
                or args.get("size", "full") not in ("full", "small")
                or args["effort"] not in models.get(args["model"], ())):
            return tool_reply("Invalid peer tool, mode or model/effort combination", True)
        request = {**args, "id": uuid.uuid4().hex, "target": tool[4:], "token": self.token, "version": 1}
        frame = json.dumps(request, ensure_ascii=True).encode("ascii") + b"\n"
        if len(frame) > MAX_REQUEST_BYTES:
            return tool_reply("Peer request is too large", True)
        try:
            async with asyncio.timeout(615):
                reader, writer = await asyncio.open_unix_connection(self.socket, limit=MAX_REPLY_BYTES + 1)
                try:
                    writer.write(frame)
                    await writer.drain()
                    response = json.loads(await reader.readline())
                finally:
                    writer.close()
                    await writer.wait_closed()
        except (OSError, ValueError, TimeoutError, RecursionError):
            return tool_reply("Peer relay is unavailable or returned invalid data", True)
        if not isinstance(response, dict):
            return tool_reply("Invalid peer relay response", True)
        if isinstance(response.get("error"), str):
            return tool_reply(response["error"], True)
        return tool_reply(json.dumps(response["result"], ensure_ascii=True)) if "result" in response else tool_reply("Missing peer result", True)


def tool_reply(text, error=False):
    return {"content": [{"type": "text", "text": text}], "isError": error}


async def read_frame(reader):
    oversized = False
    while True:
        try:
            line = await reader.readuntil(b"\n")
        except asyncio.LimitOverrunError as exc:
            oversized = True
            await reader.readexactly(exc.consumed)
        except asyncio.IncompleteReadError:
            return b""
        else:
            return None if oversized or len(line) > MAX_REQUEST_BYTES else line


async def serve(proxy, reader, send):
    pending = {}

    async def finish(request_id, params):
        result = await proxy.call(params)
        send({"jsonrpc": "2.0", "id": request_id, "result": result})

    def forget(request_id, task):
        pending.pop(request_id, None)
        if not task.cancelled():
            task.exception()

    try:
        while True:
            line = await read_frame(reader)
            if line == b"":
                break
            if line is None:
                send({"jsonrpc": "2.0", "id": None,
                      "error": {"code": -32600, "message": "Peer request frame is too large"}})
                continue
            try:
                message = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
                continue
            method = message.get("method")
            params = message.get("params", {})
            if not isinstance(params, dict):
                params = {}
            request_id = message.get("id")
            if method == "notifications/cancelled":
                cancel_id = params.get("requestId")
                if type(cancel_id) in (int, str) and cancel_id in pending:
                    pending[cancel_id].cancel()
                continue
            if type(request_id) not in (int, str) or request_id in pending:
                continue
            reply = {"jsonrpc": "2.0", "id": request_id}
            if method == "initialize":
                requested = params.get("protocolVersion")
                reply["result"] = {"protocolVersion": requested if requested in PROTOCOLS else PROTOCOLS[-1],
                                   "capabilities": {"tools": {}},
                                   "serverInfo": {"name": "cbox-peers", "version": "1"}}
            elif method == "ping":
                reply["result"] = {}
            elif method == "tools/list":
                reply["result"] = proxy.list_tools()
            elif method == "tools/call":
                if len(pending) < MAX_CONCURRENT_CALLS:
                    task = asyncio.create_task(finish(request_id, params))
                    pending[request_id] = task
                    task.add_done_callback(lambda done, key=request_id: forget(key, done))
                    continue
                reply["result"] = tool_reply("Too many pending peer turns", True)
            else:
                reply["error"] = {"code": -32601, "message": "Method not found"}
            send(reply)
    finally:
        tasks = list(pending.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def stdio(proxy):
    reader = asyncio.StreamReader(limit=MAX_REQUEST_BYTES)
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer,
    )
    try:
        def send(message):
            print(json.dumps(message, ensure_ascii=True), flush=True)

        await serve(proxy, reader, send)
    finally:
        transport.close()


def main():
    parser = argparse.ArgumentParser(description="CBOX peer MCP proxy for a private session relay")
    parser.add_argument("--engine", choices=ENGINES, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--capability-file", type=Path, required=True)
    args = parser.parse_args()
    try:
        with args.catalog.open("rb") as stream:
            catalog = json.loads(stream.read(MAX_REQUEST_BYTES + 1))
        with args.capability_file.open("r", encoding="ascii") as cap:
            token = cap.read(45).strip()
        asyncio.run(stdio(PeerMcp(args.engine, catalog, args.socket, token)))
    except (OSError, ValueError, RecursionError):
        parser.exit(1, "cbox-peer-mcp: invalid configuration or closed transport\n")


if __name__ == "__main__":
    main()
