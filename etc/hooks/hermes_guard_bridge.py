#!/usr/bin/env python3
import json
import os
import re
import shlex
import subprocess
import sys

GUARD_TIMEOUT = 5
INSTALL_VERBS = {
    "pipx": {"install", "run"},
    "poetry": {"add", "install"},
    "conda": {"install", "create"},
    "mamba": {"install", "create"},
    "micromamba": {"install", "create"},
    "npm": {"install", "i", "add", "ci", "exec"},
    "pnpm": {"install", "i", "add"},
    "yarn": {"install", "i", "add"},
    "bun": {"install", "i", "add", "x"},
    "apt": {"install", "add"},
    "apt-get": {"install", "add"},
    "dnf": {"install", "add"},
    "yum": {"install", "add"},
    "apk": {"install", "add"},
    "zypper": {"install", "add"},
    "gem": {"install"},
    "cargo": {"install"},
    "go": {"install", "get"},
}
BARE_INSTALL_TOOLS = {"npx", "uvx", "bunx"}
PIP_VERBS = {"install", "download", "wheel"}
PIP_NAME_RE = re.compile(r"^pip\d*(?:\.\d+)?$")
PYTHON_NAME_RE = re.compile(r"^python\d*(?:\.\d+)?$")
SEPARATORS = ("&&", "||", ";", "|", "&", "\n", ")", "`")


def _tool_name(token):
    return os.path.basename(token).lower()


def _next_action(tokens, start):
    if start is None:
        return ""
    for token in tokens[start:]:
        if token in SEPARATORS:
            return ""
        if token.startswith("-") or token == "--":
            continue
        return token.lower()
    return ""


def _flag_present(tokens, start, flag):
    for token in tokens[start:]:
        if token in SEPARATORS:
            return False
        if token.lower() == flag:
            return True
    return False


def _naive_tokens(command):
    pieces = re.split(r"[\s;&|()`]+", command)
    return [p.strip("'\"") for p in pieces if p.strip("'\"")]


def _scan_tokens(tokens):
    for i, token in enumerate(tokens):
        name = _tool_name(token)
        if name in ("sh", "bash") and i + 2 < len(tokens) and re.fullmatch(
                r"-[A-Za-z]*c[A-Za-z]*", tokens[i + 1]):
            nested = forbidden_install(tokens[i + 2])
            if nested:
                return nested
        if PYTHON_NAME_RE.fullmatch(name):
            module, verb_start = None, None
            if i + 1 < len(tokens) and tokens[i + 1] == "-m":
                if i + 2 < len(tokens):
                    module, verb_start = tokens[i + 2], i + 3
            elif i + 1 < len(tokens):
                squished = re.fullmatch(r"-m(\S+)", tokens[i + 1])
                if squished:
                    module, verb_start = squished.group(1), i + 2
            if module and PIP_NAME_RE.fullmatch(module.lower()) and \
                    _next_action(tokens, verb_start) in PIP_VERBS:
                return "python -m pip"
        if name == "uv":
            action = _next_action(tokens, i + 1)
            if action in ("add", "sync"):
                return "uv " + action
            if action in ("pip", "tool") and _next_action(tokens, i + 2) == "install":
                return "uv " + action + " install"
            if action == "run" and _flag_present(tokens, i + 2, "--with"):
                return "uv run --with"
        if name in BARE_INSTALL_TOOLS:
            return name
        if name == "yarn" and _next_action(tokens, i + 1) == "":
            return "yarn (bare invocation runs install)"
        if name == "conda" and _next_action(tokens, i + 1) == "env" and \
                _next_action(tokens, i + 2) == "create":
            return "conda env create"
        if name == "go" and _next_action(tokens, i + 1) == "mod" and \
                _next_action(tokens, i + 2) == "download":
            return "go mod download"
        if PIP_NAME_RE.fullmatch(name):
            action = _next_action(tokens, i + 1)
            if action in PIP_VERBS:
                return name + " " + action
            continue
        if name in INSTALL_VERBS:
            action = _next_action(tokens, i + 1)
            if action in INSTALL_VERBS[name]:
                return name + " " + action
    return None


def forbidden_install(command):
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>`")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        tokens = _naive_tokens(command)
    return _scan_tokens(tokens)


def _guard_dir():
    return os.path.dirname(os.path.abspath(__file__))


def _run_guard(name, payload_bytes):
    path = os.path.join(_guard_dir(), name)
    r = subprocess.run(
        [sys.executable, path],
        input=payload_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=GUARD_TIMEOUT,
    )
    return r.returncode, r.stdout, r.stderr


def _allow(note=None):
    if note:
        sys.stderr.write(note + "\n")
    sys.exit(0)


def _block(reason):
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}) + "\n")
    sys.exit(0)


def main():
    raw = sys.stdin.read()
    payload = json.loads(raw)

    if payload.get("hook_event_name") != "pre_tool_call":
        return _allow()
    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return _allow()
    if tool_name == "terminal":
        command = tool_input.get("command")
    elif tool_name == "process":
        if tool_input.get("action") not in ("write", "submit"):
            return _allow()
        command = tool_input.get("data")
    else:
        return _allow()
    if not isinstance(command, str) or not command:
        return _allow()
    denied = forbidden_install(command)
    if denied:
        return _block("Network package installation is disabled in delegate agent mode (%s). Report the missing package instead." % denied)

    cwd = payload.get("cwd") or ""
    claude_shaped = {
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": cwd,
    }
    payload_bytes = json.dumps(claude_shaped).encode("utf-8")

    rc, out, err = _run_guard("rm_glob_guard.py", payload_bytes)
    if rc == 2:
        reason = err.decode("utf-8", "replace").strip() or "rm-glob-guard denied this command"
        return _block(reason)

    rc2, out2, err2 = _run_guard("commit_guard.py", payload_bytes)
    note = None
    if out2:
        try:
            decoded = json.loads(out2.decode("utf-8", "replace"))
            reason = (decoded.get("hookSpecificOutput") or {}).get("permissionDecisionReason")
            if reason:
                note = "hermes_guard_bridge: commit_guard advisory (not blocking): %s" % reason
        except Exception:
            pass

    return _allow(note)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        _block("internal guard error: hermes_guard_bridge failed to inspect this "
               "tool call (%s), not a package-install denial" % type(e).__name__)
