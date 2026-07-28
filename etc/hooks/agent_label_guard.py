import json
import os
import re
import sys

EXEMPT = {"", "Explore", "Plan", "general-purpose", "claude", "fork"}


def label_re(atype):
    return re.compile(
        r"^" + re.escape(atype) + r"\s*\([A-Za-z0-9.\-]+(?:/[A-Za-z0-9.\-]+)?\):\s*"
    )


def frontmatter(path):
    meta = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            if f.readline().strip() != "---":
                return meta
            for line in f:
                if line.strip() == "---":
                    break
                m = re.match(r"^(\w+):\s*(.+?)\s*$", line)
                if m and m.group(2).strip():
                    meta[m.group(1)] = m.group(2).strip()
    except OSError:
        pass
    return meta


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Agent":
        return
    ti = data.get("tool_input") or {}
    atype = ti.get("subagent_type") or ""
    if atype in EXEMPT:
        return
    if "/" in atype or "\\" in atype or ".." in atype:
        return
    desc = ti.get("description") or ""
    meta = frontmatter(os.path.expanduser("~/.claude/agents/%s.md" % atype))
    model = ti.get("model") or meta.get("model") or "inherit"
    if model.isalpha():
        model = os.environ.get("ANTHROPIC_DEFAULT_%s_MODEL" % model.upper()) or model
    deny = os.environ.get("CBOX_AGENT_MODEL_DENY") or ""
    if deny and re.search(deny, model) and "safety-fallback" not in desc:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "model '%s' matches the spawn deny pattern; it is allowed only as a safety fallback - retry with a 'safety-fallback:' note in the description" % model,
            }
        }))
        return
    effort = meta.get("effort") or ""
    if effort:
        prefix = "%s (%s/%s): " % (atype, model, effort)
    else:
        prefix = "%s (%s): " % (atype, model)
    if desc.startswith(prefix):
        return
    task = label_re(atype).sub("", desc)
    new_ti = dict(ti)
    new_ti["description"] = prefix + task
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": new_ti,
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
