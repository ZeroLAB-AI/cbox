#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.error
import urllib.request

SERVER_NAME = "cbox-local-model"
SERVER_VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2024-11-05"
DEPTH_VAR = "CBOX_DELEGATION_DEPTH"
LEGACY_DEPTH_VAR = "CBOX_MCP_DEPTH"

URL_VAR = "CBOX_LOCAL_MODEL_URL"
NAME_VAR = "CBOX_LOCAL_MODEL_NAME"
TIMEOUT_VAR = "CBOX_LOCAL_MODEL_TIMEOUT_SEC"
MAX_PROMPT_VAR = "CBOX_LOCAL_MODEL_MAX_PROMPT_BYTES"
MAX_RESPONSE_VAR = "CBOX_LOCAL_MODEL_MAX_RESPONSE_BYTES"
AUDIT_VAR = "CBOX_LOCAL_MODEL_AUDIT"

DEFAULT_TIMEOUT_SEC = 120
DEFAULT_MAX_PROMPT_BYTES = 200000
DEFAULT_MAX_RESPONSE_BYTES = 2000000
AUDIT_MAX_BYTES = 5000000
AUDIT_LINE_MAX = 2048

TOOL_NAME = "local-complete"


def depth_reached():
    return bool(os.environ.get(DEPTH_VAR) or os.environ.get(LEGACY_DEPTH_VAR))


def int_env(name, default):
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        val = int(raw)
    except ValueError:
        return default
    return val if val > 0 else default


def base_url():
    url = os.environ.get(URL_VAR, "").strip()
    return url.rstrip("/") if url else ""


def model_name():
    return os.environ.get(NAME_VAR, "").strip()


def audit_path():
    return os.environ.get(
        AUDIT_VAR,
        os.path.expanduser("~/.claude/local_model_audit.container.jsonl"))


def send(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def reply(req_id, result):
    send({"jsonrpc": "2.0", "id": req_id, "result": result})


def reply_error(req_id, code, message):
    send({"jsonrpc": "2.0", "id": req_id,
          "error": {"code": code, "message": message}})


def tool_text(text, is_error=False):
    return {"content": [{"type": "text", "text": text}],
            "isError": is_error}


def audit(decision, reason, duration_sec, prompt_bytes, response_bytes):
    try:
        path = audit_path()
        if os.path.isfile(path) and os.path.getsize(path) > AUDIT_MAX_BYTES:
            os.replace(path, path + ".1")
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "decision": decision[:16],
               "reason": reason[:128] if reason else "",
               "model": model_name()[:80],
               "duration_sec": round(duration_sec, 3)
               if duration_sec is not None else None,
               "prompt_bytes": prompt_bytes,
               "response_bytes": response_bytes}
        line = json.dumps(rec, ensure_ascii=True)
        if len(line.encode("utf-8")) > AUDIT_LINE_MAX:
            line = json.dumps(
                {"ts": rec["ts"], "event": "audit-record-truncated"},
                ensure_ascii=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def tool_description():
    return (
        "Send one text prompt to a local model reachable over an "
        "OpenAI-compatible HTTP endpoint (for example ollama). Text-only: "
        "this tool has no filesystem or shell access, and does not spawn a "
        "subprocess. Endpoint and model are fixed by the container "
        "operator, not the caller.")


def build_tool():
    return {
        "name": TOOL_NAME,
        "description": tool_description(),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "The prompt to send to the local model."},
                "system": {
                    "type": "string",
                    "description": "Optional system message."},
                "temperature": {
                    "type": "number",
                    "minimum": 0,
                    "maximum": 2,
                    "description": "Optional sampling temperature."},
            },
            "required": ["prompt"],
        },
    }


def health_probe():
    url = base_url()
    if not url:
        return False, URL_VAR + " is not set"
    req = urllib.request.Request(url + "/api/tags", method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read(1)
        return True, ""
    except urllib.error.HTTPError as e:
        if e.code < 500:
            return True, ""
        return False, "health probe HTTP %d" % e.code
    except Exception as e:
        return False, "health probe failed: %s" % type(e).__name__


def call_endpoint(prompt, system, temperature):
    url = base_url()
    model = model_name()
    if not url:
        return None, URL_VAR + " is not set"
    if not model:
        return None, NAME_VAR + " is not set"

    max_prompt = int_env(MAX_PROMPT_VAR, DEFAULT_MAX_PROMPT_BYTES)
    prompt_bytes = len(prompt.encode("utf-8", "replace"))
    if prompt_bytes > max_prompt:
        return None, "prompt exceeds max size (%d > %d bytes)" % (
            prompt_bytes, max_prompt)

    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    body = {"model": model, "messages": messages, "stream": False}
    if temperature is not None:
        body["temperature"] = temperature

    payload = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url + "/v1/chat/completions",
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json"})

    timeout = int_env(TIMEOUT_VAR, DEFAULT_TIMEOUT_SEC)
    max_response = int_env(MAX_RESPONSE_VAR, DEFAULT_MAX_RESPONSE_BYTES)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(max_response + 1)
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read(2000).decode("utf-8", "replace")
        except Exception:
            pass
        return None, "endpoint returned HTTP %d%s" % (
            e.code, (": " + detail) if detail else "")
    except urllib.error.URLError as e:
        return None, "endpoint unreachable: %s" % e.reason
    except TimeoutError:
        return None, "endpoint timed out after %ds" % timeout
    except Exception as e:
        return None, "request failed: %s" % type(e).__name__

    if len(raw) > max_response:
        return None, "response exceeds max size (%d bytes)" % max_response

    try:
        parsed = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return None, "endpoint returned non-JSON response"

    choices = parsed.get("choices")
    if not isinstance(choices, list) or not choices:
        return None, "endpoint response has no choices"
    message = choices[0].get("message") if isinstance(choices[0], dict) \
        else None
    text = message.get("content") if isinstance(message, dict) else None
    if not isinstance(text, str):
        return None, "endpoint response has no message content"
    return text, None


def run_local_complete(args):
    if depth_reached():
        audit("deny", "depth limit", None, None, None)
        return tool_text(
            "local-complete refused: delegation depth limit reached - a "
            "delegate spawned over MCP may not spawn another one", True)

    prompt = args.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return tool_text(
            "local-complete refused: prompt must be a non-empty string",
            True)
    system = args.get("system")
    if system is not None and not isinstance(system, str):
        return tool_text(
            "local-complete refused: system must be a string", True)
    temperature = args.get("temperature")
    if temperature is not None and not isinstance(temperature, (int, float)):
        return tool_text(
            "local-complete refused: temperature must be a number", True)

    prompt_bytes = len(prompt.encode("utf-8", "replace"))
    start = time.monotonic()
    text, err = call_endpoint(prompt, system, temperature)
    duration = time.monotonic() - start

    if err is not None:
        audit("error", err, duration, prompt_bytes, None)
        return tool_text("local-complete failed: " + err, True)

    response_bytes = len(text.encode("utf-8", "replace"))
    audit("allow", "", duration, prompt_bytes, response_bytes)
    return tool_text(text)


def handle(msg):
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        params = msg.get("params") or {}
        proto = params.get("protocolVersion")
        if not isinstance(proto, str) or not proto:
            proto = DEFAULT_PROTOCOL
        reply(req_id, {
            "protocolVersion": proto,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME,
                           "version": SERVER_VERSION}})
    elif method == "ping":
        reply(req_id, {})
    elif method == "tools/list":
        if depth_reached():
            reply(req_id, {"tools": []})
            return
        reply(req_id, {"tools": [build_tool()]})
    elif method == "tools/call":
        params = msg.get("params") or {}
        if params.get("name") != TOOL_NAME:
            reply_error(req_id, -32602,
                        "unknown tool: " + str(params.get("name")))
            return
        reply(req_id, run_local_complete(params.get("arguments") or {}))
    elif req_id is not None:
        reply_error(req_id, -32601, "method not found: " + str(method))


def main():
    if not base_url():
        sys.stderr.write(
            "local_model_mcp.py: " + URL_VAR + " is not set - refusing to "
            "start; see cbox/etc/docs/LOCAL_MODEL_RUNBOOK.md\n")
        return 2
    ok, reason = health_probe()
    if not ok:
        sys.stderr.write(
            "local_model_mcp.py: startup health probe against " +
            base_url() + " failed (" + reason + ") - starting anyway, "
            "calls will fail until the endpoint is reachable\n")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None,
                  "error": {"code": -32700, "message": "parse error"}})
            continue
        try:
            handle(msg)
        except Exception as e:
            if msg.get("id") is not None:
                reply_error(msg.get("id"), -32603,
                            "internal error: " + type(e).__name__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
