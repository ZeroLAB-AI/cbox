#!/usr/bin/env python3
import errno
import json
import os
import sys


def cmd_json_seed():
    mcp = json.loads(sys.argv[2])
    flag = sys.argv[3]
    seed = {"hasCompletedOnboarding": True, "mcpServers": mcp}
    if flag in ("on", "off"):
        seed["switchModelsOnFlag"] = flag == "on"
    sys.stdout.write(json.dumps(seed, separators=(",", ":")))


def cmd_switch_flag_merge():
    target, flag = sys.argv[2], sys.argv[3]
    try:
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            cur = json.load(fh)
    except (OSError, ValueError):
        sys.exit(0)
    if not isinstance(cur, dict):
        sys.exit(0)
    if "switchModelsOnFlag" in cur:
        sys.exit(0)
    cur["switchModelsOnFlag"] = flag == "on"
    sys.stdout.write(json.dumps(cur, separators=(",", ":")))


def cmd_seed_adopt_nofollow():
    migrate, target = sys.argv[2], sys.argv[3]
    try:
        fd = os.open(migrate, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        sys.exit(0)
    try:
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        sys.exit(0)
    if not isinstance(data, dict):
        sys.exit(0)
    body = json.dumps(data, separators=(",", ":")).encode("utf-8")
    try:
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        if e.errno == errno.ELOOP:
            sys.exit(0)
        sys.exit(0)
    with os.fdopen(fd, "wb") as fh:
        fh.write(body)


def cmd_cbox_json_seed_merge():
    mcp = json.loads(sys.argv[2])
    cur = {}
    try:
        fd = os.open(sys.argv[3], os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            cur = json.load(fh)
    except (OSError, ValueError):
        cur = {}
    if not isinstance(cur, dict):
        cur = {}
    try:
        with open(sys.argv[4], "r", encoding="utf-8") as fh:
            known_cbox = set(json.load(fh).keys())
    except (OSError, ValueError):
        known_cbox = set()
    existing = cur.get("mcpServers")
    if not isinstance(existing, dict):
        existing = {}
    for name in list(existing):
        if name in known_cbox and name not in mcp:
            existing.pop(name, None)
    existing.update(mcp)
    cur["hasCompletedOnboarding"] = True
    cur["mcpServers"] = existing
    sys.stdout.write(json.dumps(cur, separators=(",", ":")))


def cmd_settings_merge():
    src, home = sys.argv[2], sys.argv[3]
    with open(src) as fh:
        text = fh.read()
    text = text.replace("@HOME@", home)
    settings = json.loads(text)
    sys.stdout.write(json.dumps(settings, separators=(",", ":")))


COMMANDS = {
    "json-seed": cmd_json_seed,
    "switch-flag-merge": cmd_switch_flag_merge,
    "seed-adopt-nofollow": cmd_seed_adopt_nofollow,
    "cbox-json-seed-merge": cmd_cbox_json_seed_merge,
    "settings-merge": cmd_settings_merge,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.stderr.write(
            "usage: claude.py {%s} ...\n" % "|".join(sorted(COMMANDS))
        )
        sys.exit(2)
    COMMANDS[sys.argv[1]]()


if __name__ == "__main__":
    main()
