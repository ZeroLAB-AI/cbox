import json
import os
import re
import sys

CODE_EXT = {".sh", ".bash", ".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs",
            ".c", ".h", ".cpp", ".hpp", ".java", ".rb", ".pl", ".lua", ".yml",
            ".yaml", ".toml", ".tf"}
DOC_EXT = {".md", ".markdown", ".txt", ".rst"}
MODEL_RE = re.compile(r"claude-(?:opus|sonnet|haiku|fable|mythos)-[0-9]|"
                      r"claude-[0-9]+(?:-[0-9]+)?|"
                      r"\bgpt-[0-9]+(?:\.[0-9]+)?-(?:turbo|mini|luna|sol|terra)|"
                      r"@anthropic-ai", re.IGNORECASE)
ALLOW_MODEL = re.compile(r"claude\.ai|chatgpt\.com|claude code|codex", re.IGNORECASE)


def is_code(path):
    _, ext = os.path.splitext(path)
    if ext in DOC_EXT:
        return False
    return ext in CODE_EXT


def is_text(path):
    _, ext = os.path.splitext(path)
    return ext in CODE_EXT or ext in DOC_EXT


def added_lines(ti, tool):
    if tool == "Write":
        return (ti.get("content") or "").split("\n")
    if tool == "Edit":
        return (ti.get("new_string") or "").split("\n")
    if tool == "MultiEdit":
        out = []
        for e in ti.get("edits") or []:
            out.extend((e.get("new_string") or "").split("\n"))
        return out
    return []


def comment_line(line, path):
    s = line.strip()
    if not s:
        return False
    _, ext = os.path.splitext(path)
    if ext in (".sh", ".bash", ".py", ".rb", ".pl"):
        if s.startswith("#") and not s.startswith("#!"):
            return True
    if ext in (".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".c", ".h",
               ".cpp", ".hpp", ".java"):
        if s.startswith("//") or s.startswith("/*") or s.startswith("*"):
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
    data = json.load(sys.stdin)
    tool = data.get("tool_name") or ""
    if tool not in ("Write", "Edit", "MultiEdit"):
        return
    ti = data.get("tool_input") or {}
    path = ti.get("file_path") or ""
    if not is_text(path):
        return
    code = is_code(path)
    for line in added_lines(ti, tool):
        for ch in line:
            if ord(ch) > 127:
                deny("coding policy: no non-ASCII in committed text - remove '%s' from %s (use ASCII: ' - ' for dashes, straight quotes, no smart punctuation or emoji unless explicitly requested)" % (ch, os.path.basename(path)))
        if not code:
            continue
        if comment_line(line, path):
            deny("coding policy: no comments in code - remove '%s' and put explanation in separate docs" % line.strip()[:60])
        for m in MODEL_RE.finditer(line):
            frag = line[max(0, m.start() - 20):m.end() + 20]
            if ALLOW_MODEL.search(frag):
                continue
            deny("coding policy: no AI model names in code - remove '%s' from %s" % (m.group(0), os.path.basename(path)))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        deny("coding policy guard could not evaluate this call (%s: %s) - failing closed; fix the guard or retry"
             % (type(exc).__name__, exc))
