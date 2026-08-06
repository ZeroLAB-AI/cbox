#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys

STATE = os.environ.get(
    "CBOX_SPAWN_GATE_STATE",
    os.path.expanduser("~/.claude/hooks/spawn_gate_state.json"),
)
MAX_UNLANDED = int(os.environ.get("CBOX_SPAWN_GATE_MAX_UNLANDED", "6"))

BUILD_RE = re.compile(
    r"\b(implement|refactor|rewrite|wire|add (?:a|the|support)|"
    r"fix the|apply the|build|migrate|port)\b",
    re.I,
)
READONLY_RE = re.compile(
    r"\b(read-?only|audit|inventor|census|survey|research|review|"
    r"do not modify|produce findings|design(?: document)?|proposal only)\b",
    re.I,
)
DECISION_RE = re.compile(r"\b(DECISION|RULING|ACCEPTED|OWNER RULING)\b")


def deny(reason, hint):
    print("[spawn-gate] DENY: %s\n  %s" % (reason, hint), file=sys.stderr)
    sys.exit(2)


def repo_head():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, timeout=10, check=False,
        )
        return out.stdout.decode("ascii", "replace").strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def load_state():
    try:
        with open(STATE, encoding="ascii") as fh:
            value = json.load(fh)
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE), mode=0o700, exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w", encoding="ascii") as fh:
            json.dump(state, fh, ensure_ascii=True)
        os.replace(tmp, STATE)
    except Exception:
        pass


def spawn_text(tool, ti):
    if tool == "Agent":
        return "%s\n%s" % (ti.get("description") or "", ti.get("prompt") or "")
    return "%s\n%s" % (ti.get("description") or "", ti.get("script") or "")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    tool = data.get("tool_name")
    if tool not in ("Agent", "Workflow"):
        return
    ti = data.get("tool_input") or {}
    text = spawn_text(tool, ti)

    head = repo_head()
    state = load_state()
    if state.get("head") != head:
        state = {"head": head, "unlanded": 0}
    unlanded = int(state.get("unlanded") or 0)

    builds = bool(BUILD_RE.search(text)) and not READONLY_RE.search(text)

    if builds and not DECISION_RE.search(text):
        deny(
            "an implementing spawn must name the decision it implements",
            "put the accepted ruling in the brief (a DECISION/RULING/ACCEPTED "
            "line naming what the owner settled). If it is not settled yet, ask "
            "one question instead of building something that may be thrown away.",
        )

    if unlanded >= MAX_UNLANDED:
        deny(
            "%d spawns since the last commit on this repo" % unlanded,
            "land what is already built (verify, then commit) or abandon it "
            "before spawning more - unlanded work is what burns the quota.",
        )

    state["unlanded"] = unlanded + 1
    save_state(state)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
