#!/usr/bin/env python3
import json
import os
import sys
import time

LOG = os.environ.get(
    "CBOX_CODEX_NOTIFY_LOG",
    os.path.expanduser("~/.codex/cbox-notify.jsonl"))
MAX_BYTES = 5 * 1024 * 1024
OSC9_MAX = 60


def rotate():
    try:
        if os.path.isfile(LOG) and os.path.getsize(LOG) > MAX_BYTES:
            os.replace(LOG, LOG + ".1")
    except Exception:
        pass


def sanitize_for_terminal(text):
    return "".join(ch for ch in text if ch.isprintable())


def emit_osc9():
    try:
        if sys.stdout.isatty():
            sys.stdout.write("\033]9;codex turn complete\033\\")
            sys.stdout.flush()
    except Exception:
        pass


def safe_id(value):
    if isinstance(value, str) and len(value) <= 128:
        return value
    return None


def main():
    try:
        if len(sys.argv) < 2:
            return 0
        payload = json.loads(sys.argv[1])
        if not isinstance(payload, dict):
            return 0
        if payload.get("type") != "agent-turn-complete":
            return 0
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "event": "agent-turn-complete",
            "thread-id": safe_id(payload.get("thread-id")),
            "turn-id": safe_id(payload.get("turn-id")),
        }
        rotate()
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=True) + "\n")
        emit_osc9()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
