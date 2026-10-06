#!/usr/bin/env python3
import os
import re
import sys

SHORT = re.compile(r"^\s*-\s+(/[^:]*)(?::|\s*$)")
LONG = re.compile(r"^\s+source:\s+(\S.*?)\s*$")
VOLUMES = re.compile(r"^(\s*)volumes:\s*$")


def within(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def sources(path):
    found = []
    block_indent = None
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            indent = len(line) - len(line.lstrip(" "))
            if block_indent is not None and indent <= block_indent:
                block_indent = None
            if block_indent is None:
                match = VOLUMES.match(line)
                if match:
                    block_indent = len(match.group(1))
                continue
            match = SHORT.match(line)
            if match:
                found.append(match.group(1))
                continue
            match = LONG.match(line)
            if match:
                value = unquote(match.group(1))
                if value.startswith("/"):
                    found.append(value)
    return found


def read_roots(path):
    roots = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            kind, _, rest = line.partition("\t")
            value, _, recorded = rest.partition("\t")
            if kind in ("root", "ws", "zone", "deny") and value.startswith("/"):
                roots.append((kind, os.path.normpath(value), recorded))
    return roots


def write_roots(target, entries):
    lines = []
    for entry in entries:
        kind, _, value = entry.partition("\t")
        if kind not in ("root", "ws", "zone", "deny") or not value.startswith("/"):
            continue
        value = os.path.normpath(value)
        lines.append("%s\t%s\t%s" % (kind, value, os.path.realpath(value)))
    directory = os.path.dirname(os.path.abspath(target))
    os.makedirs(directory, exist_ok=True)
    tmp = os.path.join(directory, ".roots.%d.tmp" % os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, target)


def zones(home, xdg):
    out = []
    for path in (xdg, os.path.join(home, ".config", "cbox"), os.path.join(home, ".ssh"),
                 os.path.join(home, ".gnupg"), os.path.join(home, ".docker")):
        if path:
            out.append((os.path.normpath(path), os.path.realpath(path)))
    return out


def check(files, roots, home, xdg):
    zone_list = zones(home, xdg)
    problems = []
    declared = [(k, p, r) for k, p, r in roots if k != "deny"]
    denied = [os.path.realpath(p) for k, p, r in roots if k == "deny"]
    have_roots = bool(declared)
    seen = set()
    for compose in files:
        for raw in sources(compose):
            src = os.path.normpath(raw)
            if src in seen:
                continue
            seen.add(src)
            real = os.path.realpath(src)
            hit = [d for d in denied if within(real, d) or within(d, real)]
            if hit:
                problems.append("bind source %s resolves to %s, which exposes the protected path %s" % (src, real, hit[0]))
                continue
            owner = None
            for kind, root, recorded in declared:
                if within(src, root) and (owner is None or len(root) > len(owner[1])):
                    owner = (kind, root, recorded)
            in_zone = [z for z in zone_list if within(real, z[1])]
            if owner is not None:
                real_root = os.path.realpath(owner[1])
                if owner[2] and real_root != owner[2]:
                    problems.append("declared root %s now resolves to %s but resolved to %s when the container was rendered (bind source %s)" % (owner[1], real_root, owner[2], src))
                elif owner[0] == "ws" and real != src:
                    problems.append("bind source %s resolves to %s instead of itself - the workspace path was replaced by a symlink" % (src, real))
                elif not within(real, real_root):
                    problems.append("bind source %s resolves to %s, outside its declared root %s (%s)" % (src, real, owner[1], real_root))
                elif owner[0] in ("root", "ws") and in_zone and not any(within(real_root, z[1]) for z in in_zone):
                    problems.append("bind source %s resolves to %s inside the protected area %s" % (src, real, in_zone[0][1]))
            elif in_zone:
                legacy_ok = (not have_roots) and any(within(src, z[0]) or within(src, z[1]) for z in in_zone)
                if not legacy_ok:
                    problems.append("bind source %s resolves to %s inside the protected area %s" % (src, real, in_zone[0][1]))
    return problems


def main(argv):
    args = argv[1:]
    if args and args[0] == "roots-write" and len(args) >= 2:
        write_roots(args[1], args[2:])
        return 0
    if not args or args[0] != "check":
        sys.stderr.write("usage: cbox_bind_guard.py check <home> <xdg_runtime_dir> <roots_file|-> <compose_file>...\n")
        return 2
    if len(args) < 5:
        sys.stderr.write("usage: cbox_bind_guard.py check <home> <xdg_runtime_dir> <roots_file|-> <compose_file>...\n")
        return 2
    home, xdg, roots_file = args[1], args[2], args[3]
    files = args[4:]
    roots = []
    if roots_file != "-":
        try:
            roots = read_roots(roots_file)
        except OSError:
            roots = []
    usable = []
    for compose in files:
        if os.path.isfile(compose):
            usable.append(compose)
    problems = check(usable, roots, home, xdg)
    for problem in problems:
        sys.stderr.write("cbox: refusing to start the container - %s\n" % problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
