#!/usr/bin/env python3
import json
import os
import sys

ARCHIVE_HEADER = "# LEDGER ARCHIVE\n\n"
POINTER_LINE = "> archive: [LEDGER_ARCHIVE.md](LEDGER_ARCHIVE.md)"


def _is_pointer(line):
    return line.lstrip().startswith(">") and "LEDGER_ARCHIVE.md" in line


def _apply_patch_file_paths(command, cwd):
    if not isinstance(command, list) or not command:
        return []
    if command[0] != "apply_patch" or len(command) < 2:
        return []
    patch_text = command[1]
    if not isinstance(patch_text, str):
        return []
    paths = []
    for line in patch_text.splitlines():
        for prefix in ("*** Add File: ", "*** Update File: ", "*** Delete File: "):
            if line.startswith(prefix):
                p = line[len(prefix):].strip()
                if p:
                    if not os.path.isabs(p) and cwd:
                        p = os.path.join(cwd, p)
                    paths.append(p)
    return paths


def _extract_edited_paths(payload):
    tool_name = payload.get("tool_name", "")
    ti = payload.get("tool_input") or {}

    if tool_name in ("Edit", "Write", "MultiEdit"):
        fp = ti.get("file_path") or ""
        return [fp] if fp else []

    command = ti.get("command")
    cwd = payload.get("cwd") or ""
    paths = _apply_patch_file_paths(command, cwd)
    if paths:
        return paths

    return []


def _atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def _split_sections(content):
    lines = content.splitlines(keepends=True)
    section_starts = [i for i, line in enumerate(lines) if line.startswith("## ")]
    if not section_starts:
        return None
    chunks = []
    preamble = "".join(lines[:section_starts[0]])
    bounds = section_starts + [len(lines)]
    for idx in range(len(section_starts)):
        start = bounds[idx]
        end = bounds[idx + 1]
        chunks.append("".join(lines[start:end]))
    return preamble, chunks


def _ensure_archive_header(path):
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    return ARCHIVE_HEADER


def _prepend_archive(archive_path, moved_chunks):
    existing = _ensure_archive_header(archive_path)
    lines = existing.splitlines(keepends=True)
    section_starts = [i for i, line in enumerate(lines) if line.startswith("## ")]
    if section_starts:
        insert_at = section_starts[0]
    else:
        insert_at = len(lines)
        if lines and not lines[-1].endswith("\n"):
            lines[-1] = lines[-1] + "\n"
    header = "".join(lines[:insert_at])
    rest = "".join(lines[insert_at:])
    new_moved = "".join(moved_chunks)
    if header and not header.endswith("\n\n") and not header.endswith("\n"):
        header += "\n"
    new_content = header + new_moved + rest
    _atomic_write(archive_path, new_content)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    try:
        edited_paths = _extract_edited_paths(payload)
        file_path = ""
        for p in edited_paths:
            if p.endswith("/.cbox/LEDGER.md") or p.endswith("/.claude/LEDGER.md"):
                file_path = p
                break
        if not file_path:
            sys.exit(0)
        if not os.path.isfile(file_path):
            sys.exit(0)

        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()

        split = _split_sections(content)
        if split is None:
            sys.exit(0)
        preamble, chunks = split
        if len(chunks) < 2:
            sys.exit(0)

        keep_chunk = chunks[0]
        moved_chunks = chunks[1:]

        pointer_in_kept = any(_is_pointer(l) for l in (preamble + keep_chunk).splitlines())
        cleaned_moved = []
        for chunk in moved_chunks:
            chunk_lines = chunk.splitlines(keepends=True)
            filtered = [line for line in chunk_lines if not _is_pointer(line)]
            cleaned_moved.append("".join(filtered))
        moved_chunks = cleaned_moved

        if not pointer_in_kept:
            if keep_chunk and not keep_chunk.endswith("\n"):
                keep_chunk += "\n"
            if keep_chunk and not keep_chunk.endswith("\n\n"):
                keep_chunk += "\n"
            keep_chunk += POINTER_LINE + "\n"

        new_ledger = preamble + keep_chunk

        claude_dir = os.path.dirname(file_path)
        archive_path = os.path.join(claude_dir, "LEDGER_ARCHIVE.md")
        _prepend_archive(archive_path, moved_chunks)

        _atomic_write(file_path, new_ledger)

    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
