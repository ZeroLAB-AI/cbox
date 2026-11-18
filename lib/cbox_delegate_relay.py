import asyncio
from dataclasses import dataclass
import hmac
import json
from pathlib import Path
import re
import secrets


MAX_REQUEST_BYTES = 65536
MAX_REPLY_BYTES = 262144
MAX_REQUESTS = 4096
IDENTIFIER = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}")
MODEL_ID = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,127}")
CAPABILITY = re.compile(r"[a-zA-Z0-9_-]{43}")


class Refused(ValueError):
    pass


@dataclass(frozen=True)
class Caller:
    engine: str
    targets: frozenset
    write: bool = False


@dataclass(frozen=True)
class Turn:
    caller: str
    target: str
    cwd: Path
    prompt: str
    model: str
    effort: str
    write: bool
    size: str | None = None


class SessionRelay:
    def __init__(self, workspace, routes, *, timeout=600):
        self.workspace = Path(workspace).resolve(strict=True)
        self.routes = dict(routes)
        self.timeout = timeout
        self.callers = {}
        self.seen = set()
        self.writes = asyncio.Lock()

    def issue_main_capability(self, caller):
        if caller.engine in caller.targets or not caller.targets <= self.routes.keys():
            raise ValueError("invalid peer routes")
        token = secrets.token_urlsafe(32)
        self.callers[token] = caller
        return token

    def revoke(self, token):
        self.callers.pop(token, None)

    def authorize(self, request):
        required = {"version", "token", "id", "target", "cwd", "prompt", "model", "effort", "mode"}
        if (not isinstance(request, dict) or not required <= request.keys() <= required | {"size"}
                or type(request["version"]) is not int or request["version"] != 1):
            raise Refused("invalid relay envelope")
        token = request["token"]
        if not isinstance(token, str) or not CAPABILITY.fullmatch(token):
            raise Refused("invalid caller capability")
        caller = next((identity for key, identity in self.callers.items() if hmac.compare_digest(key, token)), None)
        if caller is None:
            raise Refused("invalid caller capability")
        request_id, target, model, effort = (request[key] for key in ("id", "target", "model", "effort"))
        if (not all(isinstance(value, str) and IDENTIFIER.fullmatch(value) for value in (request_id, target, effort))
                or not isinstance(model, str) or not MODEL_ID.fullmatch(model)):
            raise Refused("invalid request id, target, model or effort")
        if target not in caller.targets:
            raise Refused("target is unavailable for this caller")
        size = request.get("size")
        if "size" in request and (target != "hermes" or size not in ("full", "small")):
            raise Refused("slot size must be full or small for Hermes")
        mode = request["mode"]
        if mode not in ("read", "write") or (mode == "write" and not caller.write):
            raise Refused("caller is not authorized for this mode")
        prompt, cwd_value = request["prompt"], request["cwd"]
        if not isinstance(prompt, str) or not prompt.strip() or "\0" in prompt:
            raise Refused("invalid prompt")
        if not isinstance(cwd_value, str) or "\0" in cwd_value or not Path(cwd_value).is_absolute():
            raise Refused("cwd must be absolute")
        try:
            cwd = Path(cwd_value).resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise Refused("cwd must be a directory inside the workspace") from exc
        if not cwd.is_dir() or not cwd.is_relative_to(self.workspace):
            raise Refused("cwd must be a directory inside the workspace")
        key = (caller.engine, request_id)
        if key in self.seen:
            raise Refused("duplicate request id")
        if len(self.seen) >= MAX_REQUESTS:
            raise Refused("session request limit reached")
        self.seen.add(key)
        return Turn(caller.engine, target, cwd, prompt, model, effort, mode == "write", size)

    async def run(self, turn):
        async with asyncio.timeout(self.timeout):
            if turn.write:
                async with self.writes:
                    return await self.routes[turn.target](turn)
            return await self.routes[turn.target](turn)

    async def handle(self, reader, writer):
        task = disconnect = None
        try:
            try:
                line = await asyncio.wait_for(reader.readline(), timeout=5)
                if len(line) > MAX_REQUEST_BYTES or not line.endswith(b"\n"):
                    raise Refused("invalid request frame")
                try:
                    request = json.loads(line)
                except (ValueError, RecursionError) as exc:
                    raise Refused("invalid request JSON") from exc
                turn = self.authorize(request)
                task = asyncio.create_task(self.run(turn))
                disconnect = asyncio.create_task(reader.read(1))
                ready, _ = await asyncio.wait((task, disconnect), return_when=asyncio.FIRST_COMPLETED)
                if disconnect in ready:
                    return
                reply = {"result": task.result()}
            except Refused as exc:
                reply = {"error": str(exc)}
            except TimeoutError:
                reply = {"error": "relay timed out"}
            except (ValueError, OSError, RuntimeError):
                reply = {"error": "delegate failed"}
            data = json.dumps(reply, ensure_ascii=True).encode("ascii")
            if len(data) > MAX_REPLY_BYTES:
                data = b'{"error":"delegate reply exceeds limit"}'
            writer.write(data + b"\n")
            await asyncio.wait_for(writer.drain(), timeout=5)
        except (OSError, TimeoutError):
            pass
        finally:
            for item in (task, disconnect):
                if item is not None:
                    item.cancel()
            await asyncio.gather(*(item for item in (task, disconnect) if item is not None), return_exceptions=True)
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass
