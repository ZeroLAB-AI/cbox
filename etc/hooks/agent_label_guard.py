import datetime
import fcntl
import json
import os
import re
import stat
import sys
import time

GUARD_READ_CAP_BYTES = 65536
WORKFLOW_SCRIPT_CAP_BYTES = 524288


def _safe_read_bytes(path, cap=GUARD_READ_CAP_BYTES):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        chunks = []
        total = 0
        while total < cap:
            chunk = os.read(fd, min(65536, cap - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        return b"".join(chunks)
    except OSError:
        return None
    finally:
        os.close(fd)

_HOOKS_DIR = os.path.dirname(os.path.abspath(__file__))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)
try:
    import cbox_budget
except Exception:
    cbox_budget = None
try:
    import limit_watchdog
except Exception:
    limit_watchdog = None

EXEMPT = {"", "Explore", "Plan", "general-purpose", "claude", "fork"}
SUBSTITUTABLE = {"worker", "code-reviewer", "debugger", "verifier", "doc-writer"}
LOCAL_REASONS = "unavailable|verify-failed|edge-case-spec|cross-cutting|owner-explanation|security-gate|local-busy"
LOCAL_MARKER_RE = re.compile(
    r"\blocal-skip:[ \t]*(?P<reason>" + LOCAL_REASONS + r")(?:[ \t]+-[ \t]+|[ \t]*:[ \t]*)(?P<skip>[^\n]*)"
    r"|\blocal-verify:[ \t]*(?P<verify>[^\n]*)"
)
JUSTIFY_MIN_WORDS = 4
IDENT_START = re.compile(r"[A-Za-z_$]")
IDENT_CHAR = re.compile(r"[A-Za-z0-9_$]")

LOCK_DIR_VAR = "CBOX_HERMES_DELEGATE_LOCK_DIR"
DEFAULT_LOCK_DIR = "/tmp/cbox-hermes-delegate-locks"
CONCURRENCY_VAR = "CBOX_HERMES_DELEGATE_MAX_CONCURRENCY"
OLLAMA_PARALLEL_VAR = "OLLAMA_NUM_PARALLEL"
MAX_CONCURRENCY_CAP = 16


def _int_env(name, default):
    v = os.environ.get(name)
    if not v:
        return default
    try:
        return int(v)
    except ValueError:
        return default


def _hermes_concurrency_limit():
    val = _int_env(CONCURRENCY_VAR, 0)
    if val <= 0:
        val = _int_env(OLLAMA_PARALLEL_VAR, 0)
    if val <= 0:
        val = 1
    return min(val, MAX_CONCURRENCY_CAP)


def hermes_busy():
    d = os.environ.get(LOCK_DIR_VAR) or DEFAULT_LOCK_DIR
    if not os.path.isdir(d):
        return False
    limit = _hermes_concurrency_limit()
    for i in range(limit):
        path = os.path.join(d, "slot.%d" % i)
        try:
            fd = os.open(path, os.O_RDWR)
        except OSError:
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            continue
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        return False
    return True

QUOTA_B_DENY = 0.5
QUOTA_LOCAL_BUSY_MIN = 1.0
QUOTA_EXEMPT_REASONS = ("security-gate", "owner-explanation")


_QUOTA_SNAPSHOT_CACHE = {}
_REQUEST_CONTEXT = {}


def _quota_snapshot(family="claude"):
    if family in _QUOTA_SNAPSHOT_CACHE:
        return _QUOTA_SNAPSHOT_CACHE[family]
    if cbox_budget is None:
        _QUOTA_SNAPSHOT_CACHE[family] = None
        return None
    try:
        budget = cbox_budget.budget_for_family(family)
        hermes = cbox_budget.hermes_state()
    except Exception:
        _QUOTA_SNAPSHOT_CACHE[family] = None
        return None
    snap = {"budget": budget, "hermes": hermes}
    _QUOTA_SNAPSHOT_CACHE[family] = snap
    return snap


def _fmt_resets(epoch):
    if epoch is None:
        return "unknown"
    try:
        return datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return "unknown"


def _fmt_used(val):
    return "?" if val is None else "%d" % round(val)


def _quota_reason(budget, threshold=QUOTA_B_DENY):
    b = budget.get("b")
    reset_at = budget.get("resets_at") or budget.get("override_until")
    reason = ("quota: B=%.2f below %.1f (5h %s%%, 7d %s%%); blocked until %s - "
              "end your turn, cbox resumes this session then" %
              (b, threshold, _fmt_used(budget.get("five_hour_used")),
               _fmt_used(budget.get("seven_day_used")), _fmt_resets(reset_at)))
    if budget.get("status") == "override":
        reason += "; override active until %s" % _fmt_resets(budget.get("override_until"))
    if limit_watchdog is not None and reset_at is not None:
        try:
            limit_watchdog.write_regulator_marker(
                _REQUEST_CONTEXT.get("session_id"),
                _REQUEST_CONTEXT.get("transcript_path"), reset_at + 2, time.time())
        except Exception:
            pass
    return reason


def quota_deny_reason(text, family="claude"):
    snap = _quota_snapshot(family)
    if not snap:
        return None
    budget = snap["budget"]
    hermes = snap["hermes"]
    if budget.get("status") not in ("ok", "override"):
        return None
    b = budget.get("b")
    if b is None:
        return None
    if budget.get("resets_at") is None and budget.get("override_until") is None:
        return None
    if hermes.get("state") != "available":
        return None
    if b >= QUOTA_B_DENY:
        return None
    if marker_reason(text) in QUOTA_EXEMPT_REASONS:
        return None
    return _quota_reason(budget)


def quota_local_busy_deny_reason(family="claude"):
    snap = _quota_snapshot(family)
    if not snap:
        return None
    budget = snap["budget"]
    if budget.get("status") not in ("ok", "override"):
        return None
    b = budget.get("b")
    if b is None or b >= QUOTA_LOCAL_BUSY_MIN:
        return None
    if budget.get("resets_at") is None and budget.get("override_until") is None:
        return None
    return _quota_reason(budget, QUOTA_LOCAL_BUSY_MIN)


def quota_n_claude(family="claude"):
    snap = _quota_snapshot(family)
    if not snap:
        return None
    budget = snap["budget"]
    if budget.get("status") not in ("ok", "override"):
        return None
    return budget.get("n")


def label_re(atype):
    return re.compile(
        r"^" + re.escape(atype) + r"\s*\([A-Za-z0-9.\-]+(?:/[A-Za-z0-9.\-]+)?\):\s*"
    )


def frontmatter(path):
    meta = {}
    raw = _safe_read_bytes(path)
    if raw is None:
        return meta
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return meta
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return meta
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^(\w+):\s*(.+?)\s*$", line)
        if m and m.group(2).strip():
            meta[m.group(1)] = m.group(2).strip()
    return meta


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


def local_tier_installed():
    if cbox_budget is None:
        return True
    try:
        cwd = _REQUEST_CONTEXT.get("cwd") if isinstance(_REQUEST_CONTEXT, dict) else None
        return bool(cbox_budget.local_tier_present(cwd))
    except Exception:
        return True


def justification(text):
    m = LOCAL_MARKER_RE.search(text or "")
    if not m:
        return None
    raw = m.group("skip") if m.group("skip") is not None else m.group("verify")
    literal = re.sub(r"\$\{[^}]*\}", " ", raw or "")
    words = re.findall(r"[A-Za-z0-9][A-Za-z0-9./_-]*", literal)
    if len(words) < JUSTIFY_MIN_WORDS:
        return None
    return " ".join(w.lower() for w in words)


def marker_reason(text):
    m = LOCAL_MARKER_RE.search(text or "")
    if not m:
        return None
    return m.group("reason")


BUSY_FREE_HELP = ("hermes-local is free right now (no concurrency slot is held); send this "
                   "step to hermes-local instead of claiming local-busy")

MARKER_HELP = ("put the marker in this spawn's own label as 'local-skip: <%s> - <why THIS step "
               "cannot go to hermes-local, at least %d words>' (or 'local-verify: <what local "
               "result this checks>'); a reason is per step, never shared across a wave, and a "
               "marker in a shared prompt block does not count - convenience is not a reason"
               % (LOCAL_REASONS, JUSTIFY_MIN_WORDS))


def workflow_script(ti):
    script = ti.get("script")
    if isinstance(script, str) and script:
        return script
    path = ti.get("scriptPath")
    if isinstance(path, str) and path:
        raw = _safe_read_bytes(os.path.expanduser(path), WORKFLOW_SCRIPT_CAP_BYTES + 1)
        if raw is None or len(raw) > WORKFLOW_SCRIPT_CAP_BYTES:
            return None
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
    return ""


def scan_js(script):
    tokens = []
    i, n = 0, len(script)
    while i < n:
        c = script[i]
        if script.startswith("//", i):
            j = script.find("\n", i)
            i = n if j < 0 else j
            continue
        if script.startswith("/*", i):
            j = script.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c in "'\"`":
            j = i + 1
            buf = []
            while j < n and script[j] != c:
                if script[j] == "\\" and j + 1 < n:
                    buf.append(script[j:j + 2])
                    j += 2
                    continue
                buf.append(script[j])
                j += 1
            tokens.append(("str", "".join(buf), i))
            i = j + 1
            continue
        if IDENT_START.match(c):
            j = i + 1
            while j < n and IDENT_CHAR.match(script[j]):
                j += 1
            tokens.append(("id", script[i:j], i))
            i = j
            continue
        if not c.isspace():
            tokens.append(("p", c, i))
        i += 1
    return tokens


def _options_after(tokens, k):
    depth = 0
    opts = None
    for t in range(k, len(tokens)):
        kind, val, _ = tokens[t]
        if kind == "p" and val in "([{":
            depth += 1
            if depth == 2 and val == "{" and opts is None:
                opts = t
        elif kind == "p" and val in ")]}":
            depth -= 1
            if depth == 0:
                return opts, t
    return opts, len(tokens)


def _literal_prop(tokens, start, end, name):
    depth = 0
    found = None
    for t in range(start, end):
        kind, val, _ = tokens[t]
        if kind == "p" and val in "([{":
            depth += 1
        elif kind == "p" and val in ")]}":
            depth -= 1
        elif depth == 1 and kind == "id" and val == name \
                and t + 1 < end and tokens[t + 1][:2] == ("p", ":"):
            if found is not None:
                return "dynamic", None
            found = ("dynamic", None)
            if t + 2 < end and tokens[t + 2][0] == "str":
                nxt = tokens[t + 3] if t + 3 < end else ("p", "}", 0)
                if nxt[0] == "p" and nxt[1] in ",}":
                    found = ("literal", tokens[t + 2][1])
    return found if found is not None else ("absent", None)


def _script_runs_local_agent(tokens):
    for k, (kind, val, _) in enumerate(tokens):
        if kind != "id" or val != "agent":
            continue
        prev = tokens[k - 1] if k else ("p", "", 0)
        nxt = tokens[k + 1] if k + 1 < len(tokens) else ("p", "", 0)
        if prev[:2] == ("p", ".") or nxt[:2] != ("p", "("):
            continue
        opts, close = _options_after(tokens, k + 1)
        if opts is None:
            continue
        tstate, atype = _literal_prop(tokens, opts, close, "agentType")
        if tstate == "literal" and atype == "hermes-local":
            return True
    return False


def workflow_violations(script, local_first=True):
    tokens = scan_js(script)
    local_in_script = _script_runs_local_agent(tokens)
    problems = []
    seen = {}
    calls = 0
    sub_calls = 0
    for k, (kind, val, _) in enumerate(tokens):
        if kind != "id" or val != "agent":
            continue
        prev = tokens[k - 1] if k else ("p", "", 0)
        nxt = tokens[k + 1] if k + 1 < len(tokens) else ("p", "", 0)
        if prev[:2] == ("p", "."):
            continue
        if nxt[:2] != ("p", "("):
            if prev[0] == "id" and prev[1] in ("function", "async"):
                continue
            problems.append("agent is referenced without being called (alias or pass-through); call agent() directly so each spawn can be checked")
            continue
        calls += 1
        opts, close = _options_after(tokens, k + 1)
        if opts is None:
            problems.append("agent() #%d has no literal options object; give it {label: '...', agentType: '...'} inline" % calls)
            continue
        tstate, atype = _literal_prop(tokens, opts, close, "agentType")
        if tstate != "literal":
            problems.append("agent() #%d has a %s agentType; use a literal agentType so the local-first gate can check it" % (calls, tstate))
            continue
        if atype not in SUBSTITUTABLE:
            continue
        sub_calls += 1
        lstate, label = _literal_prop(tokens, opts, close, "label")
        label_text = label if lstate == "literal" else ""
        q_reason = quota_deny_reason(label_text)
        if q_reason:
            problems.append(q_reason)
            continue
        if not local_first:
            if marker_reason(label_text) == "local-busy":
                busy_reason = quota_local_busy_deny_reason()
                if busy_reason:
                    problems.append(busy_reason)
            continue
        why = justification(label) if lstate == "literal" else None
        if why is None:
            problems.append("agent() #%d (%s) has no per-step local-skip justification in its own literal label" % (calls, atype))
            continue
        if marker_reason(label) == "local-busy":
            if not local_in_script and not hermes_busy():
                problems.append("agent() #%d (%s) claims local-busy but %s" % (calls, atype, BUSY_FREE_HELP))
                continue
            busy_reason = quota_local_busy_deny_reason()
            if busy_reason:
                problems.append(busy_reason)
                continue
        if why in seen:
            problems.append("agent() #%d (%s) reuses the justification of agent() #%d ('%s')" % (calls, atype, seen[why], why))
            continue
        seen[why] = calls
    n_claude = quota_n_claude()
    if n_claude is not None:
        cap = max(1, n_claude) + 1
        if sub_calls > cap:
            problems.append(
                "this workflow spawns %d paid substitutable agent() calls, over the quota-aware "
                "cap of %d (N claude=%d); trim the wave%s"
                % (sub_calls, cap, n_claude,
                   " or send steps to hermes-local" if local_first else ""))
    return problems


def refuse(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def main():
    global _REQUEST_CONTEXT
    data = json.load(sys.stdin)
    _REQUEST_CONTEXT = data
    if data.get("tool_name") == "Workflow":
        local_first = local_tier_installed()
        ti = data.get("tool_input")
        if not isinstance(ti, dict):
            refuse("agent_label_guard could not read the Workflow input; refusing rather than allowing it unchecked")
            return
        script = workflow_script(ti)
        if script is None:
            refuse("the workflow script at scriptPath could not be read for checking (missing, "
                   "not a regular file, a symlink, over %d bytes, or not UTF-8); pass it inline "
                   "or as a regular file" % WORKFLOW_SCRIPT_CAP_BYTES)
            return
        problems = workflow_violations(script, local_first)
        if problems:
            quota = next((p for p in problems if p.startswith("quota: B=")), None)
            if quota:
                refuse(quota)
            elif local_first:
                refuse("hermes-local is installed (priority 0) and this workflow spawns paid "
                       "substitutes without their own reason: %s; %s" % ("; ".join(problems), MARKER_HELP))
            else:
                refuse("this workflow cannot be admitted: %s" % "; ".join(problems))
        return
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
    if atype in SUBSTITUTABLE:
        local_first = local_tier_installed()
        q_reason = quota_deny_reason(desc)
        if q_reason:
            refuse(q_reason)
            return
        if local_first:
            why = justification(desc)
            if why is None:
                refuse("hermes-local is installed (priority 0) and '%s' is a priority-5 paid substitute for it; "
                     "send the task to hermes-local first, or %s" % (atype, MARKER_HELP))
                return
            if marker_reason(desc) == "local-busy" and not hermes_busy():
                refuse("'%s' claims local-busy but %s" % (atype, BUSY_FREE_HELP))
                return
        if marker_reason(desc) == "local-busy":
            busy_reason = quota_local_busy_deny_reason()
            if busy_reason:
                refuse(busy_reason)
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
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "agent_label_guard could not evaluate the spawn (%s); the quota and model gates are active, so the spawn is refused rather than allowed unchecked - fix the agent definition or payload and retry" % exc,
            }
        }))
        sys.exit(0)
