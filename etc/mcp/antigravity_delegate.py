import asyncio
import json
import os
from pathlib import Path
import re
import signal


MAX_LINE = 262144
MAX_STREAM = 4 * 1024 * 1024
CONVERSATION_ID = re.compile(r"[a-zA-Z0-9-]{1,80}")


def turn_command(binary, turn, model_efforts):
    if turn.effort not in model_efforts.get(turn.model, ()):
        raise ValueError("unsupported model and effort combination")
    return [str(binary), "--model", turn.model, "--effort", turn.effort,
            "--input-format", "stream-json", "--output-format", "stream-json"]


class TurnStream:
    def __init__(self):
        self.conversation = None
        self.result = None
        self.bytes = 0

    def accept(self, line):
        self.bytes += len(line)
        if self.bytes > MAX_STREAM or len(line) > MAX_LINE or not line.endswith(b"\n"):
            raise ValueError("invalid Antigravity stream size")
        event = json.loads(line)
        if not isinstance(event, dict) or self.result is not None:
            raise ValueError("unexpected Antigravity event")
        kind = event.get("event")
        if self.conversation is None:
            conversation = event.get("conversation_id")
            if kind != "init" or not isinstance(conversation, str) or not CONVERSATION_ID.fullmatch(conversation):
                raise ValueError("Antigravity stream is missing its init event")
            self.conversation = conversation
        elif kind == "result":
            reply = event.get("result")
            if not isinstance(reply, dict) or reply.get("conversation_id") != self.conversation:
                raise ValueError("Antigravity result has an inconsistent conversation id")
            if reply.get("status") != "SUCCESS" or not isinstance(reply.get("response"), str):
                raise ValueError("Antigravity returned an unsuccessful turn")
            self.result = {"conversation_id": self.conversation, "response": reply["response"]}
        elif kind != "step_update":
            raise ValueError("unexpected Antigravity event")


async def run_turn(binary, turn, model_efforts, *, home, progress=None):
    argv = turn_command(binary, turn, model_efforts)
    env = {"HOME": str(Path(home)), "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"}
    proc = await asyncio.create_subprocess_exec(
        *argv, cwd=turn.cwd, env=env, stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        start_new_session=True, limit=MAX_LINE,
    )
    stream = TurnStream()
    try:
        message = {"event": "user", "message": {"content": turn.prompt}}
        proc.stdin.write(json.dumps(message).encode("ascii") + b"\n")
        await proc.stdin.drain()
        proc.stdin.close()
        events = 0
        while line := await proc.stdout.readline():
            stream.accept(line)
            events += 1
            if progress is not None:
                await progress(events)
        if await proc.wait() or stream.result is None:
            raise ValueError("Antigravity exited without a successful result")
        return {**stream.result, "model": turn.model, "effort": turn.effort}
    finally:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await proc.stdout.read()
        await proc.wait()
