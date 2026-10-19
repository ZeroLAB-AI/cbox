#!/usr/bin/env python3
import json
import os
import re
import selectors
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

STATE_SCHEMA = 1
CHECK_INTERVAL_SEC = 24 * 3600
LIST_BUDGET_SEC = 5
EXPIRY_MARGIN_SEC = 60
CREDENTIALS_CAP_BYTES = 65536
CLAUDE_RESPONSE_CAP_BYTES = 1048576
CODEX_OUTPUT_CAP_BYTES = 4194304
CONFIG_SET_TIMEOUT_SEC = 180
CLAUDE_URL = "https://api.anthropic.com/v1/models?limit=100"
CLAUDE_BETA = "oauth-2025-04-20"
CLAUDE_VERSION = "2023-06-01"
DECISIONS = ("yes", "no", "never")
SERVICE = "cbox"
MAX_PROMPT_TRIES = 3
REGISTRY = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, "etc", "registry", "settings.json"
)

TIERS = (
    ("opus", "CBOX_MODEL_OPUS", "claude"),
    ("haiku", "CBOX_MODEL_HAIKU", "claude"),
    ("fable", "CBOX_MODEL_FABLE", "claude"),
    ("codex-sol", "CBOX_MODEL_CODEX_SOL", "codex"),
    ("codex-luna", "CBOX_MODEL_CODEX_LUNA", "codex"),
    ("codex-astra", "CBOX_MODEL_CODEX_ASTRA", "codex"),
)

CLAUDE_ID_RE = re.compile(
    r"^claude-(opus|sonnet|haiku|fable)-(\d{1,2})(?:-(\d{1,2}))?(?:-(\d{8}))?$"
)
CODEX_ID_RE = re.compile(r"^gpt-(\d+)(?:\.(\d+))?-([a-z]+)$")
ONE_M = "[1m]"
BANNED_CLAUDE = (("fable", 5, 1),)


def registry_defaults(path=REGISTRY):
    try:
        with open(path, "rb") as fh:
            data = json.loads(fh.read().decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError, RecursionError):
        return {}
    out = {}
    wanted = set(key for _, key, _ in TIERS)
    for var in data.get("variables", []) if isinstance(data, dict) else []:
        if isinstance(var, dict) and var.get("key") in wanted and isinstance(var.get("default"), str):
            out[var["key"]] = var["default"]
    return out


def parse_claude_id(value):
    if not isinstance(value, str):
        return None
    one_m = value.endswith(ONE_M)
    base = value[: -len(ONE_M)] if one_m else value
    m = CLAUDE_ID_RE.match(base)
    if not m:
        return None
    return {
        "base": base,
        "one_m": one_m,
        "family": m.group(1),
        "version": (int(m.group(2)), int(m.group(3) or 0)),
        "date": m.group(4),
    }


def parse_codex_id(value):
    if not isinstance(value, str):
        return None
    m = CODEX_ID_RE.match(value)
    if not m:
        return None
    return {
        "base": value,
        "version": (int(m.group(1)), int(m.group(2) or 0)),
        "tier": m.group(3),
    }


def _claude_banned(parsed):
    return (parsed["family"],) + parsed["version"] in BANNED_CLAUDE


def claude_candidate(current, ids):
    cur = parse_claude_id(current)
    if cur is None:
        return None
    best = None
    best_key = None
    for raw in ids:
        if not isinstance(raw, str) or raw.endswith(ONE_M):
            continue
        p = parse_claude_id(raw)
        if p is None or p["family"] != cur["family"] or _claude_banned(p):
            continue
        if p["version"] <= cur["version"]:
            continue
        key = (p["version"], 1 if p["date"] is None else 0, p["date"] or "")
        if best_key is None or key > best_key:
            best_key = key
            best = p
    if best is None:
        return None
    return best["base"] + (ONE_M if cur["one_m"] else "")


def codex_candidate(current, entries):
    cur = parse_codex_id(current)
    if cur is None:
        return None
    best = None
    best_version = None
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("hidden"):
            continue
        p = parse_codex_id(entry.get("id"))
        if p is None or p["tier"] != cur["tier"]:
            continue
        if p["version"] <= cur["version"]:
            continue
        if best_version is None or p["version"] > best_version:
            best_version = p["version"]
            best = p["base"]
    return best


def is_newer(kind, current, candidate):
    if kind == "claude":
        a, b = parse_claude_id(current), parse_claude_id(candidate)
        return bool(
            a and b and a["family"] == b["family"]
            and b["version"] > a["version"] and not _claude_banned(b)
        )
    a, b = parse_codex_id(current), parse_codex_id(candidate)
    return bool(a and b and a["tier"] == b["tier"] and b["version"] > a["version"])


def current_pins(env, defaults=None):
    defaults = registry_defaults() if defaults is None else defaults
    pins = []
    for tier, key, kind in TIERS:
        value = (env.get(key) or "").strip() or defaults.get(key, "")
        if value:
            pins.append((tier, key, kind, value))
    return pins


def default_state_path():
    return os.path.join(os.path.expanduser("~"), ".config", "cbox", "model-updates.json")


def new_state():
    return {"schema": STATE_SCHEMA, "last_check": 0, "decisions": {}}


def _int(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(value)


def load_state(path):
    state = new_state()
    try:
        with open(path, "rb") as fh:
            raw = fh.read(1048576)
        data = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError, RecursionError):
        return state
    if not isinstance(data, dict) or data.get("schema") != STATE_SCHEMA:
        return state
    last = _int(data.get("last_check"))
    if last is not None:
        state["last_check"] = last
    decisions = data.get("decisions")
    if isinstance(decisions, dict):
        for tier, entry in decisions.items():
            if not isinstance(tier, str) or not isinstance(entry, dict):
                continue
            cand, dec, ts = entry.get("candidate"), entry.get("decision"), _int(entry.get("ts"))
            if isinstance(cand, str) and dec in DECISIONS and ts is not None:
                state["decisions"][tier] = {"candidate": cand, "decision": dec, "ts": ts}
    return state


def save_state(path, state):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".model-updates.", dir=directory)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def is_due(state, now):
    last = state.get("last_check", 0)
    if not last or last > now + 60:
        return True
    return now - last >= CHECK_INTERVAL_SEC


def should_ask(state, tier, candidate, now, forced):
    entry = state["decisions"].get(tier)
    if not entry or entry["candidate"] != candidate:
        return True
    if entry["decision"] == "never":
        return False
    if entry["decision"] == "no" and not forced and now - entry["ts"] < CHECK_INTERVAL_SEC:
        return False
    return True


def _safe_read_bytes(path, cap):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        return os.read(fd, cap)
    except OSError:
        return None
    finally:
        os.close(fd)


def credential_paths(env):
    paths = []
    d = (env.get("CLAUDE_SECURESTORAGE_CONFIG_DIR") or "").strip()
    if d:
        paths.append(os.path.join(os.path.expanduser(d), ".credentials.json"))
    paths.append(os.path.join(os.path.expanduser("~"), ".claude", ".credentials.json"))
    out = []
    for p in paths:
        if p not in out:
            out.append(p)
    return out


def read_token(env, now):
    for path in credential_paths(env):
        raw = _safe_read_bytes(path, CREDENTIALS_CAP_BYTES)
        if raw is None:
            continue
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, RecursionError):
            continue
        oauth = data.get("claudeAiOauth") if isinstance(data, dict) else None
        if not isinstance(oauth, dict):
            continue
        token = oauth.get("accessToken")
        expires_ms = oauth.get("expiresAt")
        if isinstance(expires_ms, bool) or not isinstance(expires_ms, (int, float)):
            continue
        if not isinstance(token, str) or not token:
            continue
        if not token.isprintable() or any(ch.isspace() for ch in token):
            continue
        if expires_ms / 1000.0 - now <= EXPIRY_MARGIN_SEC:
            return None, "login token expires within 60 s"
        return token, ""
    return None, "no login token"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_claude_ids(token, timeout=LIST_BUDGET_SEC):
    req = urllib.request.Request(
        CLAUDE_URL,
        headers={"anthropic-version": CLAUDE_VERSION, "anthropic-beta": CLAUDE_BETA},
        method="GET",
    )
    req.add_unredirected_header("Authorization", "Bearer " + token)
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read(CLAUDE_RESPONSE_CAP_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise RuntimeError("HTTP %s" % exc.code)
    except (urllib.error.URLError, OSError):
        raise RuntimeError("network error")
    if len(raw) > CLAUDE_RESPONSE_CAP_BYTES:
        raise RuntimeError("response too large")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise RuntimeError("unreadable response")
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list):
        raise RuntimeError("unexpected response")
    return [d["id"] for d in data if isinstance(d, dict) and isinstance(d.get("id"), str)]


def with_budget(fn, seconds):
    box = {}

    def target():
        try:
            box["value"] = fn()
        except BaseException as exc:
            box["error"] = exc

    th = threading.Thread(target=target, daemon=True)
    th.start()
    th.join(seconds)
    if th.is_alive():
        raise TimeoutError("timed out after %d s" % seconds)
    if "error" in box:
        raise box["error"]
    return box.get("value")


def container_running(prefix, timeout=LIST_BUDGET_SEC):
    try:
        proc = subprocess.run(
            list(prefix) + ["ps", "-q", SERVICE],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0 and bool(proc.stdout.strip())


def list_codex_models(prefix, budget=LIST_BUDGET_SEC):
    argv = list(prefix) + ["exec", "-T", SERVICE, "/entrypoint.sh", "bash", "-c", "exec codex app-server"]
    deadline = time.monotonic() + budget
    proc = subprocess.Popen(
        argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
    )
    try:
        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ)
        state = {"buf": b"", "total": 0}

        def send(obj):
            proc.stdin.write((json.dumps(obj) + "\n").encode("utf-8"))
            proc.stdin.flush()

        def response(want):
            while True:
                while b"\n" in state["buf"]:
                    line, state["buf"] = state["buf"].split(b"\n", 1)
                    try:
                        msg = json.loads(line.decode("utf-8"))
                    except (ValueError, UnicodeDecodeError):
                        continue
                    if isinstance(msg, dict) and msg.get("id") == want and ("result" in msg or "error" in msg):
                        return msg
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not sel.select(remaining):
                    raise TimeoutError("timed out after %d s" % budget)
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("codex app-server closed")
                state["total"] += len(chunk)
                if state["total"] > CODEX_OUTPUT_CAP_BYTES:
                    raise RuntimeError("codex output too large")
                state["buf"] += chunk

        send({"id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "cbox-model-check", "title": "cbox model check", "version": "1"}}})
        first = response(1)
        if "error" in first:
            raise RuntimeError("codex initialize refused")
        send({"method": "initialized"})
        send({"id": 2, "method": "model/list", "params": {"includeHidden": True}})
        second = response(2)
        result = second.get("result")
        data = result.get("data") if isinstance(result, dict) else None
        if not isinstance(data, list):
            raise RuntimeError("unexpected codex model list")
        return [e for e in data if isinstance(e, dict) and isinstance(e.get("id"), str)]
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except (OSError, subprocess.SubprocessError):
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.stdout.close()
        except OSError:
            pass


def run_config_set(cbox, key, value):
    try:
        proc = subprocess.run(
            [cbox, "config", "set", "%s=%s" % (key, value)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=CONFIG_SET_TIMEOUT_SEC,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, str(exc)
    if proc.returncode == 0:
        return True, ""
    text = proc.stderr.decode("utf-8", "replace").strip().splitlines()
    return False, text[-1] if text else "exit %d" % proc.returncode


def parse_answer(text):
    t = (text or "").strip().lower()
    if t in ("y", "yes"):
        return "yes"
    if t in ("n", "no"):
        return "no"
    if t in ("v", "never"):
        return "never"
    return None


def ask(tier, current, candidate, input_fn):
    prompt = "cbox: newer model for %s: %s -> %s. Update? [y]es / [n]o / ne[v]er: " % (tier, current, candidate)
    for _ in range(MAX_PROMPT_TRIES):
        line = input_fn(prompt)
        if line is None:
            return None
        answer = parse_answer(line)
        if answer:
            return answer
    return None


def host_steps(applied, env, forced):
    keys = [k for _, k, _ in applied]
    claude_changed = any(k in ("CBOX_MODEL_OPUS", "CBOX_MODEL_HAIKU", "CBOX_MODEL_FABLE") for k in keys)
    codex_changed = any(k.startswith("CBOX_MODEL_CODEX_") for k in keys)
    mount = (env.get("CBOX_CLAUDE_MODE") or "mount") == "mount"
    lines = ["cbox: saved " + ", ".join("%s=%s" % (k, v) for _, k, v in applied)]
    if claude_changed and forced:
        lines.append(
            "cbox: the next cbox run re-renders the effective settings and recreates the container because its "
            "configuration changed; to apply now run: cbox down && cbox run <claude|codex|hermes> (isolated project) "
            "or cbox down && cbox up (global mode)"
        )
    elif claude_changed:
        lines.append(
            "cbox: this start re-renders the effective settings and recreates the container because its "
            "configuration changed; sessions still running in that container end"
        )
    if codex_changed:
        lines.append(
            "cbox: the codex delegate models are read from the rendered MCP config when claude starts; "
            "claude sessions that are already running keep the old model until restarted"
        )
    if mount and claude_changed:
        lines.append("cbox: mount mode also needs this host step for ~/.claude/settings.json: cbox setup update settings")
    if mount and codex_changed:
        lines.append("cbox: mount mode also needs this host step for ~/.claude.json: cbox setup update mcp-servers")
    return lines


def cached_report(state, pins):
    items = []
    for tier, _key, kind, value in pins:
        entry = state["decisions"].get(tier)
        if entry and entry["decision"] == "no" and is_newer(kind, value, entry["candidate"]):
            items.append("%s %s -> %s" % (tier, value, entry["candidate"]))
    if not items:
        return None
    return "cbox: newer models available: " + "; ".join(items) + " (answer with: cbox models check)"


def gather_offers(pins, claude_ids, codex_entries):
    offers = []
    for tier, key, kind, value in pins:
        if kind == "claude" and claude_ids is not None:
            cand = claude_candidate(value, claude_ids)
        elif kind == "codex" and codex_entries is not None:
            cand = codex_candidate(value, codex_entries)
        else:
            cand = None
        if cand and cand != value:
            offers.append((tier, key, kind, value, cand))
    return offers


def _save_quiet(path, state, err):
    try:
        save_state(path, state)
    except OSError as exc:
        print("cbox: model check: cannot save %s (%s)" % (path, exc.strerror or exc), file=err)


def run(mode, env, state_path, cbox, prefix, now=None, tty=None, input_fn=None,
        out=None, err=None, claude_lister=None, codex_lister=None, config_setter=None,
        running_probe=None, defaults=None):
    out = out or sys.stdout
    err = err or sys.stderr
    forced = mode == "check"
    now = int(time.time() if now is None else now)
    if tty is None:
        tty = sys.stdin.isatty() and sys.stdout.isatty()
    if (env.get("CBOX_MODEL_CHECK") or "on").strip() == "off":
        if forced:
            print("cbox: model check is off (CBOX_MODEL_CHECK=off); enable it with: cbox config set CBOX_MODEL_CHECK=on", file=err)
        return 0
    pins = current_pins(env, defaults)
    state = load_state(state_path)

    if not forced and not tty:
        line = cached_report(state, pins)
        if line:
            print(line, file=err)
        return 0
    if not forced and not is_due(state, now):
        return 0

    notes = []
    claude_ids = None
    codex_entries = None
    codex_deferred = False

    if claude_lister is None:
        def claude_lister():
            token, why = read_token(env, now)
            if token is None:
                raise RuntimeError(why)
            return with_budget(lambda: fetch_claude_ids(token), LIST_BUDGET_SEC)
    try:
        claude_ids = claude_lister()
    except Exception as exc:
        notes.append("claude list unavailable (%s)" % (exc,))

    if not prefix:
        notes.append("codex list skipped (no container configuration for this scope)")
    else:
        probe = running_probe or container_running
        if not probe(prefix):
            codex_deferred = True
            notes.append("codex list skipped (the project container is not running)")
        else:
            if codex_lister is None:
                def codex_lister():
                    return with_budget(lambda: list_codex_models(prefix), LIST_BUDGET_SEC + 3)
            try:
                codex_entries = codex_lister()
            except Exception as exc:
                notes.append("codex list unavailable (%s)" % (exc,))

    if notes and (forced or not codex_deferred or claude_ids is None):
        print("cbox: model check: " + "; ".join(notes), file=err)

    offers = gather_offers(pins, claude_ids, codex_entries)
    stamp = not (codex_deferred and not forced and claude_ids is not None)

    if not tty:
        if offers:
            print("cbox: newer models available: " + "; ".join(
                "%s %s -> %s" % (t, v, c) for t, _k, _kd, v, c in offers), file=out)
        elif not notes:
            print("cbox: model check: all pinned models are current", file=out)
        return 0

    if input_fn is None:
        def input_fn(prompt):
            sys.stderr.write(prompt)
            sys.stderr.flush()
            line = sys.stdin.readline()
            return line if line else None
    if config_setter is None:
        def config_setter(key, value):
            return run_config_set(cbox, key, value)

    applied = []
    failed = False
    try:
        for tier, key, kind, value, cand in offers:
            if not should_ask(state, tier, cand, now, forced):
                continue
            answer = ask(tier, value, cand, input_fn)
            if answer is None:
                break
            if answer == "yes":
                ok, why = config_setter(key, cand)
                if not ok:
                    failed = True
                    print("cbox: model update for %s not applied: %s" % (tier, why), file=err)
                    continue
                applied.append((tier, key, cand))
            state["decisions"][tier] = {"candidate": cand, "decision": answer, "ts": now}
            _save_quiet(state_path, state, err)
    except (KeyboardInterrupt, EOFError):
        print("", file=err)

    if stamp:
        state["last_check"] = now
        _save_quiet(state_path, state, err)

    if applied:
        for line in host_steps(applied, env, forced):
            print(line, file=err)
    elif forced and not offers and not notes:
        print("cbox: model check: all pinned models are current", file=out)
    return 1 if failed and forced else 0


def main(argv):
    if len(argv) < 2 or argv[0] not in ("start", "check"):
        print("usage: cbox_model_check.py {start|check} --cbox <path> [--state <path>] [-- <compose argv...>]", file=sys.stderr)
        return 2
    mode = argv[0]
    rest = argv[1:]
    prefix = []
    if "--" in rest:
        i = rest.index("--")
        prefix = rest[i + 1:]
        rest = rest[:i]
    cbox = None
    state_path = default_state_path()
    i = 0
    while i < len(rest):
        if rest[i] == "--cbox" and i + 1 < len(rest):
            cbox = rest[i + 1]
            i += 2
        elif rest[i] == "--state" and i + 1 < len(rest):
            state_path = rest[i + 1]
            i += 2
        else:
            print("cbox_model_check.py: unknown argument %s" % rest[i], file=sys.stderr)
            return 2
    if not cbox:
        print("cbox_model_check.py: --cbox is required", file=sys.stderr)
        return 2
    try:
        return run(mode, dict(os.environ), state_path, cbox, prefix)
    except Exception as exc:
        if mode == "check":
            print("cbox: model check failed: %s" % (exc,), file=sys.stderr)
            return 1
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
