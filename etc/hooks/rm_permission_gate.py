#!/usr/bin/env python3
import json
import os
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

GUARD_HOME_SUBDIRS = (".claude", ".claude-cbox", ".codex")
WRAPPERS = ("sudo", "env", "command", "nohup")
INLINE_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
RM_HINT = re.compile(
    r"^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
    r"(?:(?:sudo|env|command|nohup)\s+)*(?:-\S+\s+)*(?:\S*/)?(?:rm|rmdir)\b"
)
INTERACTIVE_LONG = ("--interactive", "--interactive=always", "--interactive=yes", "--interactive=once")


def respond(behavior, reasons):
    for reason in reasons:
        print("[rm-permission-gate] %s: %s" % (behavior.upper(), reason), file=sys.stderr)
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": behavior},
                }
            }
        )
    )
    sys.exit(0)


def is_rm(token):
    base = token.rsplit("/", 1)[-1]
    if base in ("rm", "rmdir"):
        return base
    return None


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


def resolve_target(arg, literals, home):
    if "`" in arg or "$(" in arg or "{" in arg:
        return None
    if COMPLEX_EXPANSION.search(arg):
        return None

    unresolved = []

    def substitute(match):
        name = match.group(1) or match.group(2)
        if name in literals:
            return literals[name]
        if name == "HOME" and home:
            return home
        unresolved.append(name)
        return ""

    resolved = VAR_REF.sub(substitute, arg)
    if unresolved:
        return None
    if resolved == "~" or resolved.startswith("~/"):
        if not home:
            return None
        resolved = home + resolved[1:]
    return resolved


def split_glob(path):
    for i, ch in enumerate(path):
        if ch in GLOB_CHARS:
            head = path[:i]
            cut = head.rfind("/")
            if cut <= 0:
                return "/", True
            return head[:cut], True
    return path, False


def norm_abs(path):
    norm = os.path.normpath(path)
    if norm.strip("/") == "":
        norm = "/"
    return norm


def critical(path, cwd, home, recursive):
    if path == "/":
        return "rm target resolves to the filesystem root"
    if home:
        home_norm = norm_abs(home)
        if path == home_norm:
            return "rm target is the home directory itself"
        for sub in GUARD_HOME_SUBDIRS:
            root = home_norm + "/" + sub
            if path == root or path.startswith(root + "/"):
                return "rm target is inside the guard-layer tree %s" % root
    if cwd:
        cwd_norm = norm_abs(cwd)
        if path == cwd_norm:
            return "rm target is the working directory"
        if cwd_norm.startswith(path + "/"):
            return "rm target is a parent of the working directory"
    if path.count("/") == 1:
        if os.path.isdir(path) and not os.path.islink(path):
            return "rm target is the top-level directory %s" % path
        if recursive:
            return (
                "recursive rm on the root-level entry %s (a non-directory now, "
                "but a swap race could make it one)" % path
            )
    return None


def classify(path, cwd, home, recursive):
    base, had_glob = split_glob(path)
    if not base.startswith("/"):
        return "rm target is not a literal absolute path: %s" % path
    norm = norm_abs(base)
    candidates = [norm]
    if had_glob:
        resolved = os.path.realpath(norm)
    else:
        parent = os.path.realpath(os.path.dirname(norm))
        resolved = os.path.join(parent, os.path.basename(norm))
    resolved = norm_abs(resolved)
    if resolved != norm:
        candidates.append(resolved)
    for candidate in candidates:
        problem = critical(candidate, cwd, home, recursive)
        if problem:
            if had_glob:
                return "%s (glob target %s)" % (problem, path)
            return "%s (target %s)" % (problem, path)
    return None


def segment_flags(tokens):
    short = set()
    long_flags = set()
    for arg in tokens:
        if arg == FLAG_STOP:
            break
        if arg.startswith("--"):
            long_flags.add(arg)
        elif arg.startswith("-") and len(arg) > 1:
            short.update(arg[1:])
    return short, long_flags


def find_rm_index(tokens):
    for i, tok in enumerate(tokens):
        if INLINE_ASSIGN.match(tok):
            continue
        if tok in WRAPPERS:
            continue
        if tok.startswith("-") and len(tok) > 1:
            continue
        kind = is_rm(tok)
        if kind is None:
            return None, None
        return i, kind
    return None, None


def parse_command(command):
    segments = []
    saw_rm = False
    start = 0
    pieces = []
    for match in SEPARATORS.finditer(command):
        pieces.append((command[start:match.start()], start))
        start = match.end()
    pieces.append((command[start:], start))
    for segment, offset in pieces:
        segment = segment.strip()
        if not segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            if RM_HINT.match(segment):
                return None, True
            continue
        if not tokens:
            continue
        idx, kind = find_rm_index(tokens)
        if idx is None:
            continue
        saw_rm = True
        literals = literal_assignments(command, offset)
        short, long_flags = segment_flags(tokens[idx + 1:])
        targets = []
        seen_stop = False
        for arg in tokens[idx + 1:]:
            if not seen_stop and arg == FLAG_STOP:
                seen_stop = True
                continue
            if not seen_stop and arg.startswith("-") and "$" not in arg and "`" not in arg:
                continue
            targets.append(arg)
        segments.append(
            {
                "kind": kind,
                "short": short,
                "long": long_flags,
                "targets": targets,
                "literals": literals,
            }
        )
    return segments, saw_rm


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if not isinstance(payload, dict):
        sys.exit(0)
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    kind = payload.get("permission_kind")
    if kind is not None and kind != "critical_path":
        sys.exit(0)
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        sys.exit(0)
    command = tool_input.get("command")
    if not isinstance(command, str) or not command:
        sys.exit(0)

    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    home = os.environ.get("HOME")

    segments, saw_rm = parse_command(command)
    if not saw_rm:
        sys.exit(0)
    if segments is None:
        respond("deny", ["command could not be parsed for rm targets"])

    reasons = []
    for seg in segments:
        interactive = bool(seg["short"] & {"i", "I"}) or bool(
            seg["long"] & set(INTERACTIVE_LONG)
        )
        if interactive:
            reasons.append("interactive rm flags stall an unattended run")
            continue
        if seg["kind"] == "rmdir" and ("p" in seg["short"] or "--parents" in seg["long"]):
            reasons.append("rmdir --parents removes an implicit parent chain")
            continue
        recursive = bool(seg["short"] & {"r", "R", "d"}) or bool(
            seg["long"] & {"--recursive", "--dir"}
        )
        for arg in seg["targets"]:
            resolved = resolve_target(arg, seg["literals"], home)
            if resolved is None:
                reasons.append(
                    "rm target does not resolve statically to a literal path: %s" % arg
                )
                continue
            problem = classify(resolved, cwd, home, recursive)
            if problem:
                reasons.append(problem)

    if reasons:
        respond("deny", reasons)
    respond("allow", [])


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
