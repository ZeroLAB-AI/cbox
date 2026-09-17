import json
import os
import re
import sys

EXEMPT = {"", "Explore", "Plan", "general-purpose", "claude", "fork"}
SUBSTITUTABLE = {"worker", "code-reviewer", "debugger", "test-runner", "doc-writer"}
LOCAL_REASONS = "unavailable|verify-failed|edge-case-spec|cross-cutting|owner-explanation|security-gate"
LOCAL_MARKER_RE = re.compile(
    r"\blocal-skip:[ \t]*(?:" + LOCAL_REASONS + r")\b|\blocal-verify:[ \t]*\S"
)


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


LOCAL_TIER_FALSY = ("", "off", "0", "false", "no")


def resolve_model(model):
    if model.isalpha():
        return os.environ.get("ANTHROPIC_DEFAULT_%s_MODEL" % model.upper()) or model
    return model


def model_policy_reason(model, note_text):
    ban = os.environ.get("CBOX_AGENT_MODEL_BAN") or ""
    resolved = resolve_model(model)
    if ban:
        if model.isalpha() and resolved == model \
                and re.search(re.escape(model), ban, re.IGNORECASE):
            return ("alias '%s' is not pinned (ANTHROPIC_DEFAULT_%s_MODEL unset) "
                    "while the spawn ban pattern mentions it - refusing the "
                    "unresolved alias" % (model, model.upper()))
        if re.search(ban, resolved, re.IGNORECASE):
            return ("model '%s' matches the spawn ban pattern (CBOX_AGENT_MODEL_BAN); "
                    "it has no fallback exception - use the pinned tier "
                    "(ANTHROPIC_DEFAULT_*_MODEL) instead" % resolved)
    deny = os.environ.get("CBOX_AGENT_MODEL_DENY") or ""
    if deny and re.search(deny, resolved, re.IGNORECASE) \
            and "safety-fallback" not in (note_text or ""):
        return ("model '%s' matches the spawn deny pattern; it is allowed only "
                "as a safety fallback - retry with a 'safety-fallback:' note "
                "in the description" % resolved)
    return None


def _delegate_on():
    return (os.environ.get("CBOX_HERMES_DELEGATE", "").strip().lower()
            not in LOCAL_TIER_FALSY)


def local_tier_installed():
    return (os.path.isfile(os.path.expanduser("~/.claude/agents/hermes-local.md"))
            or _delegate_on())


def refuse(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Agent":
        return
    ti = data.get("tool_input") or {}
    atype = ti.get("subagent_type") or ""
    desc = ti.get("description") or ""
    explicit_model = ti.get("model") or ""
    if isinstance(explicit_model, str) and explicit_model:
        reason = model_policy_reason(explicit_model, desc)
        if reason:
            refuse(reason)
            return
    if atype in EXEMPT:
        return
    if "/" in atype or "\\" in atype or ".." in atype:
        return
    meta = frontmatter(os.path.expanduser("~/.claude/agents/%s.md" % atype))
    model = explicit_model or meta.get("model") or "inherit"
    reason = model_policy_reason(model, desc)
    if reason:
        refuse(reason)
        return
    model = resolve_model(model)
    if atype in SUBSTITUTABLE and local_tier_installed():
        text = "%s\n%s" % (desc, ti.get("prompt") or "")
        if not LOCAL_MARKER_RE.search(text):
            refuse("hermes-local is installed (priority 0) and '%s' is a priority-5 paid substitute for it; "
                 "send the task to hermes-local first, or retry with 'local-skip: <%s>' "
                 "(or 'local-verify:' when this spawn checks a local result) in the description - "
                 "convenience is not a reason" % (atype, LOCAL_REASONS))
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
    except Exception as exc:
        if os.environ.get("CBOX_AGENT_MODEL_DENY") or os.environ.get("CBOX_AGENT_MODEL_BAN"):
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "agent_label_guard could not evaluate the spawn (%s); a model deny or ban pattern is active, so the spawn is refused rather than allowed unchecked - fix the agent definition or payload and retry" % exc,
                }
            }))
        sys.exit(0)
