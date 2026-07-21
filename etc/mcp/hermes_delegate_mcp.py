#!/usr/bin/env python3
import json
import os
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

SERVER_NAME = "cbox-hermes-delegate"
SERVER_VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2024-11-05"
DEPTH_VAR = "CBOX_DELEGATION_DEPTH"
LEGACY_DEPTH_VAR = "CBOX_MCP_DEPTH"

BIN_VAR = "HERMES_BIN"
TEMPLATE_HOME_VAR = "CBOX_HERMES_DELEGATE_HOME_TEMPLATE"
PROVIDER_VAR = "CBOX_HERMES_DELEGATE_PROVIDER"
BASE_URL_VAR = "CBOX_HERMES_DELEGATE_BASE_URL"
MODEL_VAR = "CBOX_HERMES_DELEGATE_MODEL"
TIMEOUT_VAR = "CBOX_HERMES_DELEGATE_TIMEOUT_SEC"
MAX_PROMPT_VAR = "CBOX_HERMES_DELEGATE_MAX_PROMPT_BYTES"
MAX_RESPONSE_VAR = "CBOX_HERMES_DELEGATE_MAX_RESPONSE_BYTES"
AUDIT_VAR = "CBOX_HERMES_DELEGATE_AUDIT"

DEFAULT_BIN = "/opt/hermes/bin/hermes"
DEFAULT_TEMPLATE_HOME = "/etc/cbox/hermes-delegate-home"
DEFAULT_TIMEOUT_SEC = 300
DEFAULT_MAX_PROMPT_BYTES = 32000
DEFAULT_MAX_RESPONSE_BYTES = 1000000
AUDIT_MAX_BYTES = 5000000
AUDIT_LINE_MAX = 2048
CONFIG_APPLY_TIMEOUT_SEC = 20
KILL_GRACE_SEC = 5

TOOL_NAME = "hermes-delegate"

VALID_PROVIDERS = ("local", "nous", "openrouter", "openai", "anthropic")


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


def hermes_bin():
    return os.environ.get(BIN_VAR, DEFAULT_BIN)


def template_home():
    return os.environ.get(TEMPLATE_HOME_VAR, DEFAULT_TEMPLATE_HOME)


def audit_path():
    return os.environ.get(
        AUDIT_VAR,
        os.path.expanduser("~/.claude/hermes_delegate_audit.container.jsonl"))


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
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.isfile(path) and os.path.getsize(path) > AUDIT_MAX_BYTES:
            os.replace(path, path + ".1")
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "decision": decision[:16],
               "reason": reason[:128] if reason else "",
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
        "Send one text prompt to a local hermes-agent process (zero-cost "
        "local-model tier). Each call spawns a fresh, ephemeral hermes home "
        "with no skills, no auth, and no retained memory - state never "
        "survives past this one call. Model, provider, and endpoint are "
        "fixed by the container operator, not the caller.")


def build_tool():
    return {
        "name": TOOL_NAME,
        "description": tool_description(),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "The prompt to send to hermes."},
                "system": {
                    "type": "string",
                    "description": "Optional system message, prepended to "
                                    "the prompt."},
            },
            "required": ["prompt"],
        },
    }


def _is_csi_param_byte(b):
    return (0x30 <= b <= 0x39) or b in (0x3b, 0x3f)


def _is_alpha_byte(b):
    return (0x41 <= b <= 0x5a) or (0x61 <= b <= 0x7a)


def _is_ctrl_byte(b):
    return (0x00 <= b <= 0x08) or b in (0x0b, 0x0c) or (0x0e <= b <= 0x1f)


def strip_ansi(raw):
    out = bytearray()
    i = 0
    n = len(raw)
    bel_positions = [m.start() for m in re.finditer(rb"\x07", raw)]
    bel_idx = 0
    while i < n:
        b = raw[i]
        if b != 0x1b:
            if not _is_ctrl_byte(b):
                out.append(b)
            i += 1
            continue
        if i + 1 >= n:
            i += 1
            continue
        nxt = raw[i + 1]
        matched = False
        if nxt == 0x5b:
            j = i + 2
            while j < n and _is_csi_param_byte(raw[j]):
                j += 1
            if j < n and _is_alpha_byte(raw[j]):
                i = j + 1
                matched = True
        elif nxt == 0x5d:
            while bel_idx < len(bel_positions) and bel_positions[bel_idx] < i + 2:
                bel_idx += 1
            if bel_idx < len(bel_positions):
                i = bel_positions[bel_idx] + 1
                matched = True
        if not matched and 0x40 <= nxt <= 0x5f:
            i += 2
            matched = True
        if not matched:
            i += 1
    return bytes(out)


def _validate_provider(val):
    return val in VALID_PROVIDERS


def _validate_url(val):
    if not val:
        return True
    if re.search(r"[\r\n]", val):
        return False
    return bool(re.match(
        r"^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$",
        val))


def _validate_model(val):
    if not val:
        return True
    if re.search(r"[\r\n]", val):
        return False
    return bool(re.match(r"^[A-Za-z0-9._:/-]+$", val))


RUN_SHORT_MAX_STREAM_BYTES = 65536


def _run_short(argv, env, cwd, timeout_sec):
    proc = None
    try:
        proc = subprocess.Popen(
            argv, env=env, cwd=cwd,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            start_new_session=True)

        out_chunks, err_chunks = [], []
        out_total, err_total = 0, 0
        deadline = time.monotonic() + timeout_sec
        open_fds = [proc.stdout, proc.stderr]
        while open_fds:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _kill_group(proc)
                try:
                    proc.wait(timeout=KILL_GRACE_SEC)
                except Exception:
                    pass
                return None, "timed out after %ds" % timeout_sec
            rlist, _, _ = select.select(
                open_fds, [], [], min(remaining, 1.0))
            for fh in rlist:
                chunk = os.read(fh.fileno(), 65536)
                if not chunk:
                    open_fds.remove(fh)
                    continue
                if fh is proc.stdout:
                    if out_total < RUN_SHORT_MAX_STREAM_BYTES:
                        take = min(
                            len(chunk),
                            RUN_SHORT_MAX_STREAM_BYTES - out_total)
                        out_chunks.append(chunk[:take])
                        out_total += take
                else:
                    if err_total < RUN_SHORT_MAX_STREAM_BYTES:
                        take = min(
                            len(chunk),
                            RUN_SHORT_MAX_STREAM_BYTES - err_total)
                        err_chunks.append(chunk[:take])
                        err_total += take

        try:
            rc = proc.wait(timeout=KILL_GRACE_SEC)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            try:
                rc = proc.wait(timeout=KILL_GRACE_SEC)
            except Exception:
                rc = -1

        out = b"".join(out_chunks)
        err = b"".join(err_chunks)
        if rc != 0:
            return None, "exit %d: %s" % (
                rc, err.decode("utf-8", "replace")[:500])
        return out, None
    finally:
        if proc is not None and proc.poll() is None:
            _kill_group(proc)
            try:
                proc.wait(timeout=KILL_GRACE_SEC)
            except Exception:
                pass
        if proc is not None:
            for fh in (proc.stdout, proc.stderr):
                try:
                    fh.close()
                except Exception:
                    pass


def _kill_group(proc):
    try:
        pgid = os.getpgid(proc.pid)
    except ProcessLookupError:
        return
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + KILL_GRACE_SEC
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.1)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _apply_config(ephemeral_home, env_base):
    provider = os.environ.get(PROVIDER_VAR, "").strip()
    base_url = os.environ.get(BASE_URL_VAR, "").strip()
    model = os.environ.get(MODEL_VAR, "").strip()

    if provider and not _validate_provider(provider):
        return "invalid " + PROVIDER_VAR + " %r" % provider
    if base_url and not _validate_url(base_url):
        return "invalid " + BASE_URL_VAR + " %r" % base_url
    if model and not _validate_model(model):
        return "invalid " + MODEL_VAR + " %r" % model

    settings = []
    if provider:
        settings.append(("model.provider", provider))
    if base_url:
        settings.append(("model.base_url", base_url))
    if model:
        settings.append(("model.default", model))

    for key, val in settings:
        argv = [hermes_bin(), "config", "set", key, val]
        env = dict(env_base)
        env["HERMES_HOME"] = ephemeral_home
        out, err = _run_short(argv, env, ephemeral_home,
                               CONFIG_APPLY_TIMEOUT_SEC)
        if err is not None:
            return "hermes config set %s failed: %s" % (key, err)
    return None


FORBIDDEN_TEMPLATE_NAMES = ("skills", "auth.json", "mcp.json", ".env")
FORBIDDEN_TEMPLATE_SUFFIXES = (".db", ".sqlite", ".sqlite3")


class TemplateHomeContractError(Exception):
    pass


def _check_template_home_contract(tmpl):
    for entry in os.listdir(tmpl):
        if entry in FORBIDDEN_TEMPLATE_NAMES or entry.endswith(
                FORBIDDEN_TEMPLATE_SUFFIXES):
            raise TemplateHomeContractError(
                "template home contains forbidden artifact %r - refusing "
                "to seed (auth/skills/mcp-config/db must never reach the "
                "hermes delegate's ephemeral home)" % entry)


def _seed_ephemeral_home(ephemeral_home):
    tmpl = template_home()
    if os.path.isdir(tmpl):
        _check_template_home_contract(tmpl)
        for entry in os.listdir(tmpl):
            src = os.path.join(tmpl, entry)
            dst = os.path.join(ephemeral_home, entry)
            if os.path.isdir(src) and not os.path.islink(src):
                shutil.copytree(src, dst, symlinks=True)
            else:
                shutil.copy2(src, dst, follow_symlinks=False)
    else:
        os.makedirs(ephemeral_home, exist_ok=True)


def _template_home_is_hardened(tmpl):
    try:
        st = os.stat(tmpl)
    except OSError:
        return False
    if st.st_uid != 0:
        return False
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        return False
    for dirpath, dirnames, filenames in os.walk(tmpl):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            try:
                st = os.lstat(path)
            except OSError:
                return False
            if stat.S_ISLNK(st.st_mode):
                return False
            if st.st_uid != 0:
                return False
            if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                return False
    return True


def spawn_hermes(prompt, system):
    ephemeral_home = None
    proc = None
    try:
        ephemeral_home = tempfile.mkdtemp(prefix="cbox-hermes-delegate-")
        os.chmod(ephemeral_home, 0o700)
        _seed_ephemeral_home(ephemeral_home)

        env_base = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": ephemeral_home,
            "HERMES_HOME": ephemeral_home,
            "LANG": "C.UTF-8",
            DEPTH_VAR: "1",
            LEGACY_DEPTH_VAR: "1",
        }

        cfg_err = _apply_config(ephemeral_home, env_base)
        if cfg_err:
            return None, cfg_err

        full_prompt = prompt if not system else (system + "\n\n" + prompt)
        argv = [hermes_bin(), "-z", full_prompt, "--ignore-rules"]

        timeout = int_env(TIMEOUT_VAR, DEFAULT_TIMEOUT_SEC)
        max_response = int_env(MAX_RESPONSE_VAR, DEFAULT_MAX_RESPONSE_BYTES)

        env = dict(env_base)
        proc = subprocess.Popen(
            argv, env=env, cwd=ephemeral_home,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            start_new_session=True)

        chunks = []
        total = 0
        truncated = False
        deadline = time.monotonic() + timeout
        open_fds = [proc.stdout, proc.stderr]
        while open_fds:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _kill_group(proc)
                try:
                    proc.wait(timeout=KILL_GRACE_SEC)
                except Exception:
                    pass
                return None, "timed out after %ds" % timeout
            rlist, _, _ = select.select(
                open_fds, [], [], min(remaining, 1.0))
            for fh in rlist:
                chunk = os.read(fh.fileno(), 65536)
                if not chunk:
                    open_fds.remove(fh)
                    continue
                if fh is proc.stdout and not truncated:
                    if total + len(chunk) > max_response:
                        chunk = chunk[:max(0, max_response - total)]
                        truncated = True
                    chunks.append(chunk)
                    total += len(chunk)

        try:
            rc = proc.wait(timeout=KILL_GRACE_SEC)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            try:
                rc = proc.wait(timeout=KILL_GRACE_SEC)
            except Exception:
                rc = -1
        raw = b"".join(chunks)
        cleaned = strip_ansi(raw)
        text = cleaned.decode("utf-8", "replace").strip()

        if rc != 0 and not text:
            return None, "hermes exited %d with no output" % rc
        if truncated:
            text += "\n[hermes-delegate: response truncated at %d bytes]" \
                % max_response
        return text, None
    except FileNotFoundError:
        return None, "hermes binary not found or not executable: %s" \
            % hermes_bin()
    except Exception as e:
        return None, "spawn failed: %s" % type(e).__name__
    finally:
        if proc is not None and proc.poll() is None:
            _kill_group(proc)
            try:
                proc.wait(timeout=KILL_GRACE_SEC)
            except Exception:
                pass
        if proc is not None:
            for fh in (proc.stdout, proc.stderr):
                try:
                    fh.close()
                except Exception:
                    pass
        if ephemeral_home is not None:
            shutil.rmtree(ephemeral_home, ignore_errors=True)


def run_hermes_delegate(args):
    if depth_reached():
        audit("deny", "depth limit", None, None, None)
        return tool_text(
            "hermes-delegate refused: delegation depth limit reached - a "
            "delegate spawned over MCP may not spawn another one", True)

    prompt = args.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return tool_text(
            "hermes-delegate refused: prompt must be a non-empty string",
            True)
    system = args.get("system")
    if system is not None and not isinstance(system, str):
        return tool_text(
            "hermes-delegate refused: system must be a string", True)

    max_prompt = int_env(MAX_PROMPT_VAR, DEFAULT_MAX_PROMPT_BYTES)
    prompt_bytes = len(prompt.encode("utf-8", "replace"))
    system_bytes = len(system.encode("utf-8", "replace")) if system else 0
    if prompt_bytes + system_bytes > max_prompt:
        audit("deny", "prompt too large", None, prompt_bytes, None)
        return tool_text(
            "hermes-delegate refused: prompt exceeds max size (%d > %d "
            "bytes)" % (prompt_bytes + system_bytes, max_prompt), True)

    start = time.monotonic()
    text, err = spawn_hermes(prompt, system)
    duration = time.monotonic() - start

    if err is not None:
        audit("error", err, duration, prompt_bytes, None)
        return tool_text("hermes-delegate failed: " + err, True)

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
        reply(req_id, run_hermes_delegate(params.get("arguments") or {}))
    elif req_id is not None:
        reply_error(req_id, -32601, "method not found: " + str(method))


def main():
    binp = hermes_bin()
    if not (os.path.isfile(binp) and os.access(binp, os.X_OK)):
        sys.stderr.write(
            "hermes_delegate_mcp.py: " + BIN_VAR + " (" + binp + ") is not "
            "an executable file - refusing to start\n")
        return 2
    tmpl = template_home()
    if not os.path.isdir(tmpl):
        sys.stderr.write(
            "hermes_delegate_mcp.py: " + TEMPLATE_HOME_VAR + " (" +
            tmpl + ") does not exist - refusing to start\n")
        return 2
    if not _template_home_is_hardened(tmpl):
        sys.stderr.write(
            "hermes_delegate_mcp.py: " + TEMPLATE_HOME_VAR + " (" +
            tmpl + ") is not root-owned, read-only, and symlink-free - "
            "refusing to start\n")
        return 2

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
