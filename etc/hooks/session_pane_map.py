#!/usr/bin/env python3
import json
import os
import re
import socket
import sys
import time

SID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def load_markers(markers_dir, own_sid):
    pending = []
    try:
        names = sorted(os.listdir(markers_dir))
    except OSError:
        return pending
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(markers_dir, name)) as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        if rec.get("state") != "pending":
            continue
        sid = rec.get("sessionId")
        if not isinstance(sid, str) or not SID_RE.match(sid):
            continue
        if sid == own_sid:
            continue
        pending.append(rec)
    return pending


def render(pending):
    lines = ["Sessions in this scope were stopped by a usage limit and "
             "are waiting to continue:"]
    for rec in pending[:10]:
        reset = rec.get("resetAt")
        when = "unknown reset time"
        if isinstance(reset, (int, float)) and reset > 0:
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(reset))
        cwd = rec.get("cwd")
        if not isinstance(cwd, str):
            cwd = "?"
        lines.append("- session %s (cwd %s, limit reset %s)" % (
            rec.get("sessionId", "?"), (cwd or "?")[:200], when))
    lines.append(
        "If a session has no live pane to auto-resume, run "
        "`claude --resume <session-id>` and continue from the ledger.")
    return "\n".join(lines)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
    if os.path.basename(cfg.rstrip("/")) != ".claude-cbox":
        return 0
    if not os.path.isdir(cfg):
        return 0
    sid = data.get("session_id") or ""
    if not isinstance(sid, str) or not SID_RE.match(sid):
        return 0
    watch = os.path.join(cfg, "limit-watch")
    panes = os.path.join(watch, "panes")
    path = os.path.join(panes, sid + ".json")
    event = data.get("hook_event_name") or ""
    if event == "SessionEnd":
        try:
            os.unlink(path)
        except OSError:
            pass
        return 0
    if event != "SessionStart":
        return 0
    try:
        os.makedirs(panes, exist_ok=True)
        rec = {
            "pane": os.environ.get("TMUX_PANE") or None,
            "container": socket.gethostname(),
            "cwd": data.get("cwd") or "",
            "transcript": data.get("transcript_path") or "",
            "at": int(time.time()),
        }
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(rec, fh)
        os.replace(tmp, path)
    except OSError:
        pass
    pending = load_markers(os.path.join(watch, "markers"), sid)
    if pending:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": render(pending)}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
