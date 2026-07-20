#!/usr/bin/env python3
import fcntl
import json
import os
import re
import subprocess
import sys

CHANGELOG_HEADER = "# CHANGELOG\n\n## [Unmerged]\n"
UNMERGED_LINE = "## [Unmerged]"
FS = "\x1f"
RS = "\x1e"


def _project_dir(payload):
    env_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if env_dir:
        return env_dir
    ti = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or ti.get("cwd")
    if cwd:
        return cwd
    return None


def _command_text(command):
    if isinstance(command, str):
        return command
    if isinstance(command, list):
        return " ".join(c for c in command if isinstance(c, str))
    return ""


def _brain_dir(proj):
    cbox_dir = os.path.join(proj, ".cbox")
    claude_dir = os.path.join(proj, ".claude")
    if os.path.isfile(os.path.join(cbox_dir, "LEDGER.md")):
        return cbox_dir
    if os.path.isfile(os.path.join(claude_dir, "LEDGER.md")):
        return claude_dir
    return None


def _read_state(state_path):
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("last_commit"), str):
            if re.fullmatch(r"[0-9a-fA-F]{7,64}", data["last_commit"]):
                return data["last_commit"]
    except Exception:
        pass
    return None


def _atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def _write_state(state_path, commit_hash):
    _atomic_write(state_path, json.dumps({"last_commit": commit_hash}))


def _acquire_lock(state_path):
    lock_path = state_path + ".lock"
    fh = open(lock_path, "a+")
    fcntl.flock(fh, fcntl.LOCK_EX)
    return fh


def _release_lock(fh):
    try:
        fcntl.flock(fh, fcntl.LOCK_UN)
    finally:
        fh.close()


def _is_ancestor(proj, commit_hash):
    out = subprocess.run(
        ["git", "-C", proj, "merge-base", "--is-ancestor", commit_hash, "HEAD"],
        capture_output=True, timeout=10)
    return out.returncode == 0


def _git_log(proj, rev_range):
    out = subprocess.run(
        ["git", "-C", proj, "log",
         "--format=%H" + FS + "%h" + FS + "%ad" + FS + "%s" + FS + "%b" + RS,
         "--date=format:%Y-%m-%d", "--reverse", rev_range],
        capture_output=True, timeout=10)
    if out.returncode != 0:
        return []
    text = out.stdout.decode("utf-8", "replace")
    entries = []
    for chunk in text.split(RS):
        chunk = chunk.strip("\n")
        if not chunk.strip():
            continue
        parts = chunk.split(FS)
        if len(parts) < 5:
            continue
        full_hash, short_hash, date, subject, body = parts[0], parts[1], parts[2], parts[3], parts[4]
        entries.append({
            "full": full_hash, "short": short_hash, "date": date,
            "subject": subject, "body": body,
        })
    return entries


def _head_hash(proj):
    out = subprocess.run(["git", "-C", proj, "rev-parse", "HEAD"],
                          capture_output=True, timeout=10)
    if out.returncode != 0:
        return None
    return out.stdout.decode("utf-8", "replace").strip()


def _body_lines(body):
    lines = []
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.lower().startswith("co-authored-by:"):
            continue
        lines.append(stripped)
    return lines


def _changelog_section(entry):
    dash = "\u2014"
    lines = ["## [%s] %s %s" % (entry["short"], dash, entry["date"])]
    lines.append("- %s" % entry["subject"])
    for bl in _body_lines(entry["body"]):
        lines.append("- %s" % bl)
    return "\n".join(lines) + "\n"


def _insert_into_changelog(changelog_path, sections_text):
    if os.path.isfile(changelog_path):
        with open(changelog_path, "r", encoding="utf-8") as f:
            content = f.read()
    else:
        content = CHANGELOG_HEADER

    lines = content.splitlines(keepends=True)
    insert_at = None
    for i, line in enumerate(lines):
        if line.strip() == UNMERGED_LINE:
            insert_at = i + 1
            while insert_at < len(lines) and not lines[insert_at].startswith("## "):
                insert_at += 1
            break
    if insert_at is None:
        for i, line in enumerate(lines):
            if line.startswith("# ") and not line.startswith("## "):
                insert_at = i + 1
                while insert_at < len(lines) and lines[insert_at].strip() == "":
                    insert_at += 1
                break
    if insert_at is None:
        insert_at = len(lines)

    prefix = "".join(lines[:insert_at])
    suffix = "".join(lines[insert_at:])
    if prefix and not prefix.endswith("\n\n") and not prefix.endswith("\n"):
        prefix += "\n"
    if prefix and not prefix.endswith("\n\n"):
        prefix += "\n"

    new_content = prefix + sections_text + "\n" + suffix
    _atomic_write(changelog_path, new_content)


def _progress_date_str(progress_path):
    base = os.path.basename(progress_path)
    stem = base
    if stem.endswith(".md"):
        stem = stem[:-3]
    prefix = "PROGRESS_"
    if stem.startswith(prefix):
        stem = stem[len(prefix):]
    return stem.replace("_", "-")


def _append_progress(progress_path, lines):
    if not os.path.isfile(progress_path):
        with open(progress_path, "w", encoding="utf-8") as f:
            f.write("# PROGRESS %s\n\n" % _progress_date_str(progress_path))
    with open(progress_path, "a", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    try:
        tool_name = payload.get("tool_name", "")
        known_shell_tools = ("Bash", "shell", "local_shell", "exec", "exec_command", "unified_exec")
        if tool_name not in known_shell_tools:
            sys.exit(0)
        ti = payload.get("tool_input") or {}
        command = _command_text(ti.get("command"))
        if "git commit" not in command:
            sys.exit(0)

        proj = _project_dir(payload)
        if not proj or not os.path.isdir(proj):
            sys.exit(0)

        claude_dir = _brain_dir(proj)
        if not claude_dir:
            sys.exit(0)

        state_path = os.path.join(claude_dir, ".continuity_state.json")
        changelog_path = os.path.join(claude_dir, "CHANGELOG.md")

        lock_fh = _acquire_lock(state_path)
        try:
            last_commit = _read_state(state_path)
            if last_commit is not None and not _is_ancestor(proj, last_commit):
                last_commit = None

            if last_commit is None:
                head = _head_hash(proj)
                if not head:
                    sys.exit(0)
                out = subprocess.run(
                    ["git", "-C", proj, "log", "-1",
                     "--format=%H" + FS + "%h" + FS + "%ad" + FS + "%s" + FS + "%b" + RS,
                     "--date=format:%Y-%m-%d"],
                    capture_output=True, timeout=10)
                entries = []
                if out.returncode == 0:
                    text = out.stdout.decode("utf-8", "replace")
                    for chunk in text.split(RS):
                        chunk = chunk.strip("\n")
                        if not chunk.strip():
                            continue
                        parts = chunk.split(FS)
                        if len(parts) < 5:
                            continue
                        entries.append({
                            "full": parts[0], "short": parts[1], "date": parts[2],
                            "subject": parts[3], "body": parts[4],
                        })
            else:
                entries = _git_log(proj, last_commit + "..HEAD")

            if not entries:
                head = _head_hash(proj)
                if head:
                    _write_state(state_path, head)
                sys.exit(0)

            sections_text = "\n".join(_changelog_section(e) for e in reversed(entries))
            _insert_into_changelog(changelog_path, sections_text)

            today_str = None
            try:
                import datetime
                today_str = datetime.date.today().strftime("%Y_%m_%d")
            except Exception:
                today_str = None
            if today_str:
                progress_path = os.path.join(claude_dir, "PROGRESS_%s.md" % today_str)
                prog_lines = ["- [auto] commit %s: %s" % (e["short"], e["subject"]) for e in entries]
                _append_progress(progress_path, prog_lines)

            head = _head_hash(proj)
            if head:
                _write_state(state_path, head)
        finally:
            _release_lock(lock_fh)

    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
