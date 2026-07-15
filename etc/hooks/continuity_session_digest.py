#!/usr/bin/env python3
import json
import os
import sys

TEST_MARKERS = ("pytest", "bash -n", "verify", "npm test", "npm run test")


def _project_dir(payload):
    env_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if env_dir:
        return env_dir
    cwd = payload.get("cwd")
    if cwd:
        return cwd
    return None


def _agent_label(tool_input):
    desc = tool_input.get("description") if isinstance(tool_input, dict) else None
    if isinstance(desc, str) and desc.strip():
        return desc.strip().split(":")[0].strip()
    return None


def _looks_like_test_cmd(command):
    if not isinstance(command, str):
        return False
    low = command.lower()
    return any(marker in low for marker in TEST_MARKERS)


def _parse_transcript(transcript_path):
    assistant_turns = 0
    tool_counts = {}
    agent_labels = []
    edited_files = []
    seen_files = set()
    test_cmds = 0

    try:
        records = 0
        with open(transcript_path, "r", encoding="utf-8") as f:
            for raw_line in f:
                if len(raw_line) > 1000000:
                    continue
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                records += 1
                if records > 100000:
                    break
                try:
                    rec = json.loads(raw_line)
                except Exception:
                    continue
                if not isinstance(rec, dict):
                    continue

                rec_type = rec.get("type")
                message = rec.get("message") if isinstance(rec.get("message"), dict) else {}

                if rec_type == "assistant" or message.get("role") == "assistant":
                    assistant_turns += 1

                content = message.get("content")
                if isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "tool_use":
                            name = block.get("name") or "unknown"
                            tool_counts[name] = tool_counts.get(name, 0) + 1
                            tin = block.get("input") or {}
                            if name == "Agent":
                                label = _agent_label(tin)
                                if label:
                                    agent_labels.append(label)
                            if name in ("Edit", "Write", "MultiEdit"):
                                fp = tin.get("file_path")
                                if isinstance(fp, str) and fp:
                                    base = os.path.basename(fp)
                                    if base not in seen_files:
                                        seen_files.add(base)
                                        edited_files.append(base)
                            if name == "Bash":
                                cmd = tin.get("command")
                                if _looks_like_test_cmd(cmd):
                                    test_cmds += 1
    except Exception:
        return None

    return {
        "assistant_turns": assistant_turns,
        "tool_counts": tool_counts,
        "agent_labels": agent_labels,
        "edited_files": edited_files[:10],
        "test_cmds": test_cmds,
    }


def _progress_date_str(progress_path):
    base = os.path.basename(progress_path)
    stem = base
    if stem.endswith(".md"):
        stem = stem[:-3]
    prefix = "PROGRESS_"
    if stem.startswith(prefix):
        stem = stem[len(prefix):]
    return stem.replace("_", "-")


def _append_progress(progress_path, block_lines):
    if not os.path.isfile(progress_path):
        with open(progress_path, "w", encoding="utf-8") as f:
            f.write("# PROGRESS %s\n\n" % _progress_date_str(progress_path))
    with open(progress_path, "a", encoding="utf-8") as f:
        for line in block_lines:
            f.write(line + "\n")


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    try:
        session_id = payload.get("session_id")
        transcript_path = payload.get("transcript_path")
        if not isinstance(session_id, str) or not session_id:
            sys.exit(0)
        if not isinstance(transcript_path, str) or not transcript_path:
            sys.exit(0)
        if not os.path.isfile(transcript_path):
            sys.exit(0)

        proj = _project_dir(payload)
        if not proj or not os.path.isdir(proj):
            sys.exit(0)

        claude_dir = os.path.join(proj, ".claude")
        ledger_path = os.path.join(claude_dir, "LEDGER.md")
        if not os.path.isfile(ledger_path):
            sys.exit(0)

        digest = _parse_transcript(transcript_path)
        if digest is None:
            sys.exit(0)

        top_tools = sorted(digest["tool_counts"].items(), key=lambda kv: -kv[1])[:5]
        tools_str = ", ".join("%s=%d" % (name, count) for name, count in top_tools)

        agents = digest["agent_labels"]
        agents_str = ", ".join(agents[:5]) if agents else "none"

        edits_str = ", ".join(digest["edited_files"]) if digest["edited_files"] else "none"

        short_id = session_id[:8]

        line = "- [auto] session %s digest: %d turns, tools: %s, agents: %s; edits: %s" % (
            short_id, digest["assistant_turns"], tools_str or "none", agents_str, edits_str)

        import datetime
        today_str = datetime.date.today().strftime("%Y_%m_%d")
        progress_path = os.path.join(claude_dir, "PROGRESS_%s.md" % today_str)
        _append_progress(progress_path, [line])

    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
