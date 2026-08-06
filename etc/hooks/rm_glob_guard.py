#!/usr/bin/env python3
import json
import re
import shlex
import sys

SEPARATORS = re.compile(r"\|\||&&|[;|\n]")
GLOB_CHARS = ("*", "?", "[")
FLAG_STOP = "--"

VAR_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
COMPLEX_EXPANSION = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*[^}A-Za-z0-9_]")
ASSIGNMENT = re.compile(
    r"(?:^|[\s;|&(])([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"]*\"|'[^']*'|[^\s;|&]*)"
)
KNOWN_NONEMPTY_ENV = frozenset(["HOME"])


def deny(reason, offender):
    print(
        "[rm-glob-guard] DENY: %s\n"
        "  offending argument: %s\n"
        "  an rm target must resolve statically to an absolute path. Safe shapes:\n"
        "    rm -rf -- /abs/path/dir\n"
        "    rm -f -- /abs/path/dir/*\n"
        "    d=/abs/path/dir; rm -f -- \"$d\"/*\n"
        "  never build an rm target from a bare glob, command substitution, or a\n"
        "  variable not assigned a literal in the same command - shell state does\n"
        "  not persist between tool calls, so an unassigned variable expands empty,\n"
        "  and an unresolvable target stalls unattended runs on a destructive-command\n"
        "  prompt." % (reason, offender),
        file=sys.stderr,
    )
    sys.exit(2)


def is_rm(token):
    return token == "rm" or token.endswith("/rm")


def bare_glob(arg):
    if not any(ch in arg for ch in GLOB_CHARS):
        return False
    if arg.startswith("/") or arg.startswith("$"):
        return False
    return "/" not in arg


def cwd_relative_glob(arg):
    if not any(ch in arg for ch in GLOB_CHARS):
        return False
    return arg.startswith("./") or arg.startswith("../") or arg.startswith("~")


def literal_assignments(command, before):
    literals = {}
    for match in ASSIGNMENT.finditer(command):
        if match.start() >= before:
            break
        name, raw = match.group(1), match.group(2)
        if raw.startswith('"') or raw.startswith("'"):
            value = raw[1:-1]
        else:
            value = raw
        if not value or "$" in value or "`" in value:
            literals.pop(name, None)
            continue
        literals[name] = value
    return literals


def check_variable_target(arg, literals):
    if "`" in arg:
        deny("rm target contains a backquote command substitution", arg)
    if "$(" in arg:
        deny("rm target is built from command substitution", arg)
    if COMPLEX_EXPANSION.search(arg):
        deny("rm target uses a parameter expansion that cannot be resolved statically", arg)

    def substitute(match):
        name = match.group(1) or match.group(2)
        if name in literals:
            return literals[name]
        if name in KNOWN_NONEMPTY_ENV:
            return "/known-env"
        return "\x00"

    resolved = VAR_REF.sub(substitute, arg)
    if "\x00" in resolved:
        deny(
            "rm target references a variable with no literal assignment in this command "
            "(possibly empty)",
            arg,
        )
    if "$" in resolved:
        deny("rm target contains an expansion that cannot be resolved statically", arg)
    if not resolved.startswith("/"):
        deny("rm target built from variables does not resolve to an absolute path", arg)
    if resolved.rstrip("/") == "":
        deny("rm target resolves to the filesystem root", arg)


def segments_with_offsets(command):
    out = []
    start = 0
    for match in SEPARATORS.finditer(command):
        out.append((command[start:match.start()], start))
        start = match.end()
    out.append((command[start:], start))
    return out


def check(command):
    for segment, offset in segments_with_offsets(command):
        segment = segment.strip()
        if not segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            continue
        if not tokens or not is_rm(tokens[0]):
            continue
        literals = literal_assignments(command, offset)
        seen_stop = False
        for arg in tokens[1:]:
            if not seen_stop and arg == FLAG_STOP:
                seen_stop = True
                continue
            if not seen_stop and arg.startswith("-") and "$" not in arg and "`" not in arg:
                continue
            if bare_glob(arg):
                deny("rm with a bare glob has no directory anchor", arg)
            if cwd_relative_glob(arg):
                deny("rm with a glob anchored only to the current directory", arg)
            if "$" in arg or "`" in arg:
                check_variable_target(arg, literals)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        sys.exit(0)
    command = tool_input.get("command")
    if not isinstance(command, str) or not command:
        sys.exit(0)
    check(command)
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
