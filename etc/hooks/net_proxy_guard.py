#!/usr/bin/env python3
import json
import os
import re
import shlex
import sys

SEPARATORS = re.compile(r"\|\||&&|[;|\n]")
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.DOTALL)
TRIGGER_CMDS = frozenset(["export", "declare", "typeset", "env"])
NON_SETTING_FLAGS = frozenset(["-p", "-n", "+x"])
TARGET_NAME = "ALL_PROXY"
HEREDOC_RE = re.compile(r"<<-?\s*(?:'([^']*)'|\"([^\"]*)\"|([A-Za-z_][A-Za-z0-9_]*))")
INTERP_C_RE = re.compile(
    r"(?:^|[\s;&|()])(?:[\w./-]*/)?(?:python3?|sh|bash)(?:\.exe)?"
    r"\s+(?:-[A-Za-z0-9]+\s+)*-c\s+"
    r"(?P<q>['\"])(?P<body>(?:\\.|(?!(?P=q))[^\\])*)(?P=q)",
    re.DOTALL,
)
SOURCE_CMDS = frozenset([".", "source"])
SOURCED_ASSIGN_RE = re.compile(r"^\s*(?:export\s+)?all_proxy\s*=", re.IGNORECASE)
SOURCE_FILE_MAX_BYTES = 65536


def _basename(tok):
    return tok.rsplit("/", 1)[-1]


def _is_target(name):
    return name.upper() == TARGET_NAME


def _strip_heredocs(command):
    lines = command.split("\n")
    out = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        out.append(line)
        m = HEREDOC_RE.search(line)
        if not m:
            i += 1
            continue
        delim = m.group(1) or m.group(2) or m.group(3)
        i += 1
        while i < n:
            if lines[i].strip() == delim:
                i += 1
                break
            i += 1
    return "\n".join(out)


def _strip_interpreter_c_bodies(command):
    def repl(match):
        start, end = match.span()
        bstart, bend = match.span("body")
        return command[start:bstart] + command[bend:end]
    return INTERP_C_RE.sub(repl, command)


def _segment_sets_all_proxy(tokens):
    n = len(tokens)
    i = 0
    while i < n:
        m = ASSIGN_RE.match(tokens[i])
        if not m:
            break
        if _is_target(m.group(1)):
            return True
        i += 1
    if i >= n:
        return False
    cmd = _basename(tokens[i])
    if cmd not in TRIGGER_CMDS:
        return False
    j = i + 1
    while j < n:
        tok = tokens[j]
        if tok == "--":
            j += 1
            continue
        if cmd in ("export", "declare", "typeset") and tok in NON_SETTING_FLAGS:
            return False
        if (tok.startswith("-") or tok.startswith("+")) and tok not in ("-", "+"):
            j += 1
            continue
        m = ASSIGN_RE.match(tok)
        if m:
            if _is_target(m.group(1)):
                return True
            j += 1
            continue
        if cmd == "env":
            break
        if _is_target(tok):
            return True
        j += 1
    return False


def _segment_sources_all_proxy(tokens):
    if len(tokens) < 2:
        return False
    if tokens[0] not in SOURCE_CMDS:
        return False
    path = tokens[1]
    if not path or path.startswith("-"):
        return False
    try:
        if not os.path.isfile(path):
            return False
        with open(path, "r", errors="replace") as f:
            data = f.read(SOURCE_FILE_MAX_BYTES)
    except OSError:
        return False
    for line in data.splitlines():
        if SOURCED_ASSIGN_RE.match(line):
            return True
    return False


def command_sets_all_proxy(command):
    stripped = _strip_interpreter_c_bodies(command)
    stripped = _strip_heredocs(stripped)
    for segment in SEPARATORS.split(stripped):
        segment = segment.strip()
        if not segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            continue
        if not tokens:
            continue
        if _segment_sets_all_proxy(tokens):
            return True
        if _segment_sources_all_proxy(tokens):
            return True
    return False


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if not isinstance(payload, dict) or payload.get("tool_name") != "Bash":
        sys.exit(0)
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        sys.exit(0)
    command = tool_input.get("command")
    if not isinstance(command, str) or not command:
        sys.exit(0)
    netmap_path = os.environ.get("CBOX_NETMAP_FILE", "/etc/cbox/net/netmap.json")
    if not os.path.exists(netmap_path):
        sys.exit(0)
    if command_sets_all_proxy(command):
        deny("the gateway variable is CBOX_SOCKS_PROXY, not ALL_PROXY - a blanket "
             "ALL_PROXY breaks general egress; use the cbox-net net_map tool")
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
