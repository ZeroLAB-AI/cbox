#!/usr/bin/env python3
import argparse
import collections
import importlib.util
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import unicodedata

MAX_MSG = 140
MAX_LINE = 1 << 20
MAX_BACKEND_LINE = 1 << 26
MAX_CALLS = 64
MAX_THREADS = 256
MAX_JOURNAL = 500
MAX_CANCELLED_IDS = 256

DOCKERENV_PATH = "/.dockerenv"

KERNEL_FILENAME = "conduct-kernel.txt"
GUARD_MODULE_FILENAME = "codex_mode_guard.py"

DEPTH_ERROR = "codex_mcp_shim: delegation depth limit reached, tool disabled"
DEFAULT_PROTOCOL = "2024-11-05"

TURN_START_TIMEOUT_SEC = 30
THREAD_START_TIMEOUT_SEC = 30
THREAD_RESUME_TIMEOUT_SEC = 30
INTERRUPT_TIMEOUT_SEC = 15
SHUTDOWN_GRACE_SEC = 5
STDIN_EOF_GRACE_SEC = 5

DEFAULT_HEARTBEAT_SEC = 30
HEARTBEAT_ENV_VAR = "CBOX_CODEX_SHIM_HEARTBEAT_SEC"

DEFAULT_TURN_TIMEOUT_SEC = 3600
TURN_TIMEOUT_ENV_VAR = "CBOX_CODEX_SHIM_TURN_TIMEOUT_SEC"

DEFAULT_INTERRUPT_GRACE_SEC = 15
INTERRUPT_GRACE_ENV_VAR = "CBOX_CODEX_SHIM_INTERRUPT_GRACE_SEC"

CODEX_HOME_ENV_VAR = "CODEX_HOME"
THREAD_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
ROLLOUT_SCAN_FILE_LIMIT = 4000
ROLLOUT_META_READ_CAP = 65536
ROLLOUT_NEGATIVE_CACHE_MAX = 512

MAX_PROGRESS_TOKENS = 256
MAX_PROGRESS_TOKEN_LEN = 256

SHIM_AUDIT_MAX_BYTES = 5 * 1024 * 1024


def heartbeat_interval_sec():
    raw = os.environ.get(HEARTBEAT_ENV_VAR)
    if raw:
        try:
            val = int(raw)
        except ValueError:
            val = None
        if val is not None and val > 0:
            return val
    return DEFAULT_HEARTBEAT_SEC


def turn_timeout_sec():
    raw = os.environ.get(TURN_TIMEOUT_ENV_VAR)
    if raw is None or raw == "":
        return DEFAULT_TURN_TIMEOUT_SEC
    try:
        val = int(raw)
    except ValueError:
        return DEFAULT_TURN_TIMEOUT_SEC
    return val if val >= 0 else DEFAULT_TURN_TIMEOUT_SEC


def interrupt_grace_sec():
    raw = os.environ.get(INTERRUPT_GRACE_ENV_VAR)
    if raw:
        try:
            val = int(raw)
        except ValueError:
            val = None
        if val is not None and val >= 0:
            return val
    return DEFAULT_INTERRUPT_GRACE_SEC


def codex_home():
    return os.environ.get(CODEX_HOME_ENV_VAR) or os.path.expanduser("~/.codex")


def _rollout_field_from_result(result):
    if not isinstance(result, dict):
        return None
    keys = ("rolloutPath", "rollout_path", "path", "sessionFile", "session_file")
    for key in keys:
        val = result.get(key)
        if isinstance(val, str) and val:
            return val
    thread = result.get("thread")
    if isinstance(thread, dict):
        for key in keys:
            val = thread.get(key)
            if isinstance(val, str) and val:
                return val
    return None


_rollout_negative_cache = collections.OrderedDict()
_rollout_negative_cache_lock = threading.Lock()


def _rollout_negative_cache_get(key):
    with _rollout_negative_cache_lock:
        return key in _rollout_negative_cache


def _rollout_negative_cache_put(key):
    with _rollout_negative_cache_lock:
        _rollout_negative_cache[key] = True
        _rollout_negative_cache.move_to_end(key)
        while len(_rollout_negative_cache) > ROLLOUT_NEGATIVE_CACHE_MAX:
            _rollout_negative_cache.popitem(last=False)


def _listdir_dirs_desc(path):
    try:
        names = os.listdir(path)
    except OSError:
        return []
    dirs = []
    for name in names:
        try:
            if os.path.isdir(os.path.join(path, name)):
                dirs.append(name)
        except OSError:
            continue
    dirs.sort(reverse=True)
    return dirs


def _listdir_jsonl_desc(path):
    try:
        names = os.listdir(path)
    except OSError:
        return []
    names = [n for n in names if n.endswith(".jsonl")]
    names.sort(reverse=True)
    return names


def _read_rollout_first_line(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        try:
            st = os.fstat(fd)
        except OSError:
            return None
        if not stat.S_ISREG(st.st_mode):
            return None
        try:
            chunk = os.read(fd, ROLLOUT_META_READ_CAP)
        except OSError:
            return None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    nl = chunk.find(b"\n")
    if nl < 0:
        if len(chunk) >= ROLLOUT_META_READ_CAP:
            return None
        return chunk
    return chunk[:nl]


def _rollout_session_meta_payload(path):
    line = _read_rollout_first_line(path)
    if not line:
        return None
    try:
        rec = json.loads(line.decode("utf-8", errors="replace"))
    except ValueError:
        return None
    if not isinstance(rec, dict) or rec.get("type") != "session_meta":
        return None
    payload = rec.get("payload")
    return payload if isinstance(payload, dict) else None


def rollout_cwd(path):
    payload = _rollout_session_meta_payload(path)
    if payload is None:
        return None
    cwd = payload.get("cwd")
    return cwd if isinstance(cwd, str) and cwd else None


def find_rollout_path_by_thread_id(thread_id, limit=ROLLOUT_SCAN_FILE_LIMIT):
    if not isinstance(thread_id, str) or not THREAD_ID_RE.match(thread_id):
        return None
    home = codex_home()
    cache_key = (home, thread_id)
    if _rollout_negative_cache_get(cache_key):
        return None
    sessions_root = os.path.join(home, "sessions")
    suffix = "-%s.jsonl" % thread_id
    scanned = 0
    for year in _listdir_dirs_desc(sessions_root):
        year_path = os.path.join(sessions_root, year)
        for month in _listdir_dirs_desc(year_path):
            month_path = os.path.join(year_path, month)
            for day in _listdir_dirs_desc(month_path):
                day_path = os.path.join(month_path, day)
                for name in _listdir_jsonl_desc(day_path):
                    if scanned >= limit:
                        _rollout_negative_cache_put(cache_key)
                        return None
                    scanned += 1
                    path = os.path.join(day_path, name)
                    if name.endswith(suffix):
                        return path
                    payload = _rollout_session_meta_payload(path)
                    if payload is not None:
                        rid = payload.get("id") or payload.get("session_id")
                        if rid == thread_id:
                            return path
    _rollout_negative_cache_put(cache_key)
    return None


def _pdeathsig_argv_prefix(argv):
    setpriv_path = shutil.which("setpriv")
    if setpriv_path:
        return [setpriv_path, "--pdeathsig", "KILL"] + list(argv)
    return list(argv)


def _signal_group_or_proc(proc, sig):
    try:
        pgid = os.getpgid(proc.pid)
    except (OSError, AttributeError):
        pgid = None
    if pgid is not None:
        try:
            os.killpg(pgid, sig)
            return
        except (OSError, ProcessLookupError):
            pass
    try:
        proc.send_signal(sig)
    except OSError:
        pass


def _terminate_child(proc, grace_sec=SHUTDOWN_GRACE_SEC):
    if proc is None:
        return
    try:
        if proc.poll() is not None:
            return
    except Exception:
        pass
    _signal_group_or_proc(proc, signal.SIGTERM)
    try:
        proc.wait(timeout=grace_sec)
        return
    except Exception:
        pass
    _signal_group_or_proc(proc, signal.SIGKILL)
    try:
        proc.wait(timeout=grace_sec)
    except Exception:
        pass


def _guard_module_path():
    here = os.path.dirname(os.path.abspath(__file__))
    sibling = os.path.join(here, GUARD_MODULE_FILENAME)
    if os.path.isfile(sibling):
        return sibling
    repo_source = os.path.join(
        os.path.dirname(here), "hooks", GUARD_MODULE_FILENAME
    )
    if os.path.isfile(repo_source):
        return repo_source
    return sibling


def _load_guard_module():
    guard_path = _guard_module_path()
    spec = importlib.util.spec_from_file_location(
        "codex_mode_guard_for_shim", guard_path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GUARD = _load_guard_module()


def in_container():
    return os.path.exists(DOCKERENV_PATH) and os.environ.get("CBOX_RUNTIME") == "container"


def kernel_path():
    override = os.environ.get("CBOX_CONDUCT_KERNEL_PATH")
    if override and not in_container():
        return override
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), KERNEL_FILENAME)


def load_kernel():
    path = kernel_path()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        sys.stderr.write(
            "codex_mcp_shim: cannot read conduct kernel at %s: %s\n" % (path, exc)
        )
        sys.exit(2)
    if not text.strip():
        sys.stderr.write("codex_mcp_shim: conduct kernel at %s is empty\n" % path)
        sys.exit(2)
    return text


def valid_progress_token(token):
    if isinstance(token, bool):
        return False
    if isinstance(token, str):
        return len(token) <= MAX_PROGRESS_TOKEN_LEN
    if isinstance(token, int):
        return True
    return False


def sanitize(text):
    flat = "".join(
        ch if ch.isprintable() and not unicodedata.combining(ch) else " "
        for ch in str(text)
    )
    return " ".join(flat.split())[:MAX_MSG]


def check_cwd_scope_and_git(cwd):
    if not isinstance(cwd, str) or not cwd:
        return (
            "codex_mcp_shim: the codex call must have an EXPLICIT cwd "
            "(absolute working directory of the task) - add cwd to the "
            "arguments"
        )
    if not os.path.isabs(cwd):
        return (
            "codex_mcp_shim: cwd must be an ABSOLUTE path (a relative one "
            "resolves against a foreign process)"
        )
    real = os.path.realpath(cwd)
    if not os.path.isdir(real):
        return "codex_mcp_shim: cwd is not an existing directory"
    cfg = GUARD._load_config()
    roots = GUARD._allowed_roots(cfg)
    if not any(real == r or real.startswith(r + os.sep) for r in roots):
        return (
            "codex_mcp_shim: cwd is outside the allowed scope "
            "(codex_scope.json allowed_roots + CODEX_GUARD_EXTRA_ROOTS) - "
            "codex may write only there"
        )
    try:
        in_git = subprocess.run(
            ["git", "-C", real, "rev-parse", "--is-inside-work-tree"],
            capture_output=True, timeout=5,
        ).returncode == 0
    except Exception:
        in_git = False
    if not in_git:
        return (
            "codex_mcp_shim: cwd is not a git work-tree - codex changes "
            "must ALWAYS be versioned (git init in the target directory, "
            "or pick a repo)"
        )
    return None


SHIM_AUDIT_LINE_MAX = 2048


def shim_audit_path():
    return os.environ.get(
        "CODEX_SHIM_GUARD_AUDIT",
        os.path.expanduser("~/.claude/hooks/codex_shim_guard_audit.jsonl"),
    )


def _classify_call_outcome(err):
    if err is None:
        return "ok"
    low = err.lower()
    if "timed out" in low or "wall-clock cap" in low:
        return "timeout"
    if "interrupt" in low or "cancelled" in low:
        return "interrupted"
    return "error"


def shim_audit(tier, decision, reason, cwd, thread_id=None, outcome=None,
                duration_sec=None):
    try:
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "tier": tier[:64] if isinstance(tier, str) else None,
            "decision": decision[:16],
            "reason": reason[:128] if reason else "",
            "cwd_sha256": GUARD._audit_digest(cwd),
            "thread_id": thread_id[:128] if isinstance(thread_id, str) else None,
            "outcome": outcome[:32] if isinstance(outcome, str) else None,
            "duration_sec": round(duration_sec, 3) if duration_sec is not None else None,
        }
        line = json.dumps(rec, ensure_ascii=True)
        if len(line.encode("utf-8")) > SHIM_AUDIT_LINE_MAX:
            line = json.dumps(
                {"ts": rec["ts"], "event": "audit-record-truncated"},
                ensure_ascii=True,
            )
        path = shim_audit_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.isfile(path) and os.path.getsize(path) > SHIM_AUDIT_MAX_BYTES:
            os.replace(path, path + ".1")
        fd = os.open(
            path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600
        )
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass


def parse_args(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--tier", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--effort", required=True)
    parser.add_argument("--progress", required=True, choices=["on", "off"])
    parser.add_argument("child", nargs=argparse.REMAINDER)
    ns = parser.parse_args(argv)
    child = ns.child
    if child and child[0] == "--":
        child = child[1:]
    if not child:
        sys.stderr.write("codex_mcp_shim: missing child command after --\n")
        sys.exit(2)
    if not ns.tier or not ns.model or not ns.effort:
        sys.stderr.write("codex_mcp_shim: --tier, --model, --effort must be non-empty\n")
        sys.exit(2)
    return ns, child


INSTRUCTION_KEY_SUFFIXES = ("instructions", "instructions_file")

TOP_LEVEL_REJECT_KEYS = frozenset(("profile", "model_provider"))
CONFIG_ALLOW_KEYS = frozenset((
    "model_reasoning_effort",
    "model_reasoning_summary",
    "model_verbosity",
    "hide_agent_reasoning",
))
CONFIG_REJECT_KEY_WORDS = frozenset((
    "notify",
    "shell_environment_policy",
    "model_providers",
    "sandbox_mode",
    "approval_policy",
))


def _normalize_key(key):
    return key.strip().lower().replace("-", "_")


def _has_instruction_key(obj):
    for key in obj:
        if not isinstance(key, str):
            continue
        norm = _normalize_key(key)
        if norm.endswith(INSTRUCTION_KEY_SUFFIXES):
            return True
    return False


def _find_rejected_key(obj, reject_set):
    for key in obj:
        if not isinstance(key, str):
            continue
        if _normalize_key(key) in reject_set:
            return key
    return None


def policy_check_args(args, cfg):
    if _has_instruction_key(args):
        return (
            "codex_mcp_shim: caller-supplied instructions field is rejected - "
            "task direction belongs in prompt"
        )
    bad = _find_rejected_key(args, TOP_LEVEL_REJECT_KEYS)
    if bad is not None:
        return (
            "codex_mcp_shim: caller-supplied key %r is rejected by policy - "
            "it could change the pinned model, provider, sandbox or "
            "approval posture" % bad
        )
    if cfg is not None:
        if _has_instruction_key(cfg):
            return (
                "codex_mcp_shim: caller-supplied instructions field is "
                "rejected - task direction belongs in prompt"
            )
        for key in cfg:
            if not isinstance(key, str):
                continue
            norm = _normalize_key(key)
            if norm not in CONFIG_ALLOW_KEYS or isinstance(
                cfg[key], (dict, list)
            ):
                base = (
                    "codex_mcp_shim: caller-supplied config key %r is rejected "
                    "by policy - it could change the pinned model, provider, "
                    "sandbox or approval posture" % key
                )
                if norm in CONFIG_REJECT_KEY_WORDS:
                    base += " (known-forbidden key: %s)" % norm
                else:
                    base += " (not in the allow-list)"
                base += (
                    "; allowed config keys are model_reasoning_effort, "
                    "model_reasoning_summary, model_verbosity, "
                    "hide_agent_reasoning only"
                )
                return base
    return None


def read_lines(stream, max_line):
    buf = bytearray()
    while True:
        chunk = stream.read1(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            nl = buf.find(b"\n")
            if nl < 0:
                if len(buf) > max_line:
                    raise OversizedLineError(max_line)
                break
            line = bytes(buf[:nl])
            del buf[: nl + 1]
            if len(line) > max_line:
                del buf[:]
                raise OversizedLineError(max_line)
            yield line


def extract_final_text(turn):
    items = turn.get("items") if isinstance(turn, dict) else None
    if not isinstance(items, list):
        return ""
    agent_msgs = [
        it for it in items
        if isinstance(it, dict) and it.get("type") == "agentMessage"
    ]
    if not agent_msgs:
        return ""
    final = [it for it in agent_msgs if it.get("phase") == "final_answer"]
    pick = final[-1] if final else agent_msgs[-1]
    text = pick.get("text")
    return text if isinstance(text, str) else ""


def extract_turn_error(turn):
    if not isinstance(turn, dict):
        return None
    err = turn.get("error")
    if isinstance(err, dict):
        detail = err.get("additionalDetails")
        if isinstance(detail, str) and detail:
            return detail
        info = err.get("codexErrorInfo")
        if isinstance(info, str):
            return info
        if isinstance(info, dict):
            return json.dumps(info, ensure_ascii=True)[:500]
    return None


def item_progress_text(event, item):
    itype = item.get("type") if isinstance(item, dict) else None
    if itype == "commandExecution":
        cmd = item.get("command")
        if event == "item/started":
            return sanitize("exec: " + str(cmd)) if cmd else "exec started"
        status = item.get("status")
        return sanitize("exec %s" % status) if status else "exec done"
    if itype == "fileChange":
        status = item.get("status")
        if event == "item/started":
            return "file change started"
        return sanitize("file change %s" % status) if status else "file change done"
    if itype == "mcpToolCall":
        server = item.get("server")
        tool = item.get("tool")
        if event == "item/started":
            return sanitize("tool: %s.%s" % (server, tool))
        return "tool done"
    if itype == "webSearch":
        if event == "item/started":
            query = item.get("query")
            return sanitize("web: " + query) if isinstance(query, str) else "web search"
        return "web search done"
    if itype == "agentMessage" and event == "item/completed":
        text = item.get("text")
        return sanitize("msg: " + text) if isinstance(text, str) and text else None
    return None


class BackendRpcError(Exception):
    def __init__(self, error):
        self.error = error
        message = error.get("message") if isinstance(error, dict) else str(error)
        super().__init__(message)


class BackendTimeout(Exception):
    pass


class OversizedLineError(ValueError):
    def __init__(self, limit=None):
        self.limit = limit if limit is not None else MAX_BACKEND_LINE
        super().__init__("line exceeded the %d byte limit" % self.limit)


class CodexBackend:
    def __init__(self, child_argv, tier, journal_fn, progress_cb):
        self.child_argv = child_argv
        self.tier = tier
        self.journal = journal_fn
        self.progress_cb = progress_cb
        self.proc = None
        self.stdin_lock = threading.Lock()
        self.state_lock = threading.Lock()
        self.next_id = 1
        self.pending = {}
        self.turn_waiters = {}
        self.active_turn = {}
        self.initialized = False
        self.start_lock = threading.Lock()
        self.thread_turn_locks = {}
        self.thread_turn_locks_guard = threading.Lock()
        self.known_threads = {}
        self.thread_cwd = {}
        self.thread_rollout = {}
        self.thread_incarnation = {}
        self.incarnation = 0
        self.reader_thread = None
        self._spawn_cv = threading.Condition()
        self._spawn_request = None
        self._spawn_thread = threading.Thread(
            target=self._spawn_loop, daemon=True
        )
        self._spawn_thread.start()

    def _spawn_loop(self):
        while True:
            with self._spawn_cv:
                while self._spawn_request is None:
                    self._spawn_cv.wait()
                argv, env, holder, done = self._spawn_request
                self._spawn_request = None
            try:
                holder["proc"] = subprocess.Popen(
                    _pdeathsig_argv_prefix(argv),
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    env=env, start_new_session=True,
                )
            except Exception as exc:
                holder["error"] = exc
            done.set()

    def _spawn_child(self, argv, env):
        holder = {}
        done = threading.Event()
        with self._spawn_cv:
            self._spawn_request = (argv, env, holder, done)
            self._spawn_cv.notify()
        done.wait()
        if "error" in holder:
            raise holder["error"]
        return holder["proc"]

    def _dead_child_message(self, exc):
        with self.state_lock:
            proc = self.proc
        if proc is not None:
            try:
                if proc.poll() is None:
                    proc.wait(timeout=2)
            except Exception:
                pass
            code = proc.poll()
            if code is not None:
                return (
                    "codex backend child exited (code %r) before the "
                    "request completed" % (code,)
                )
        return "write to codex backend failed: %s" % exc

    def _write(self, obj):
        line = (json.dumps(obj) + "\n").encode()
        with self.stdin_lock:
            try:
                self.proc.stdin.write(line)
                self.proc.stdin.flush()
            except (ValueError, BrokenPipeError, ConnectionResetError, OSError) as exc:
                raise BackendRpcError({
                    "message": self._dead_child_message(exc),
                }) from exc

    def _next_id(self):
        with self.state_lock:
            rid = self.next_id
            self.next_id += 1
        return rid

    def request(self, method, params, timeout=60):
        rid = self._next_id()
        ev = threading.Event()
        slot = {}
        with self.state_lock:
            self.pending[rid] = (ev, slot)
        try:
            self._write({"id": rid, "method": method, "params": params})
        except BackendRpcError:
            with self.state_lock:
                self.pending.pop(rid, None)
            raise
        ok = ev.wait(timeout)
        with self.state_lock:
            self.pending.pop(rid, None)
        if not ok:
            raise BackendTimeout("%s timed out after %ds" % (method, timeout))
        if "error" in slot:
            raise BackendRpcError(slot["error"])
        return slot.get("result")

    def notify(self, method, params=None):
        obj = {"method": method}
        if params is not None:
            obj["params"] = params
        self._write(obj)

    def ensure_started(self, extra_env):
        with self.start_lock:
            with self.state_lock:
                if self.initialized and self.proc is not None \
                        and self.proc.poll() is None:
                    return
                env = dict(os.environ)
                env.update(extra_env)
                self.proc = self._spawn_child(self.child_argv, env)
                self.incarnation += 1
                self.pending = {}
                self.reader_thread = threading.Thread(
                    target=self._read_loop, daemon=True
                )
                self.reader_thread.start()
            self.journal("spawn", tier=self.tier)
            try:
                self.request(
                    "initialize",
                    {"clientInfo": {"name": "cbox-codex-shim",
                                    "title": "cbox codex shim",
                                    "version": "1"}},
                    timeout=30,
                )
                self.notify("initialized")
            except Exception as exc:
                with self.state_lock:
                    proc = self.proc
                    self.initialized = False
                    self.pending = {}
                    self.proc = None
                exit_code = None
                if proc is not None:
                    try:
                        if proc.poll() is None:
                            proc.kill()
                    except OSError:
                        pass
                    try:
                        proc.wait(timeout=5)
                        exit_code = proc.poll()
                    except Exception:
                        exit_code = proc.poll()
                message = "codex backend handshake failed: %s" % (exc,)
                if exit_code is not None:
                    message = (
                        "codex backend child exited (code %r) before the "
                        "handshake completed" % (exit_code,)
                    )
                self.journal("spawn_failed", tier=self.tier, error=message)
                raise BackendRpcError({"message": message}) from exc
            with self.state_lock:
                self.initialized = True

    def thread_is_live(self, thread_id):
        with self.state_lock:
            return self.thread_incarnation.get(thread_id) == self.incarnation

    def mark_thread_live(self, thread_id, cwd=None, rollout=None):
        with self.state_lock:
            self.thread_incarnation[thread_id] = self.incarnation
            self.known_threads.pop(thread_id, None)
            while len(self.known_threads) >= MAX_THREADS:
                self.known_threads.pop(next(iter(self.known_threads)))
            self.known_threads[thread_id] = True
            if cwd is not None:
                self.thread_cwd[thread_id] = cwd
            if rollout is not None:
                self.thread_rollout[thread_id] = rollout

    def known_thread(self, thread_id):
        with self.state_lock:
            return thread_id in self.known_threads

    def cached_cwd(self, thread_id):
        with self.state_lock:
            return self.thread_cwd.get(thread_id)

    def cached_rollout(self, thread_id):
        with self.state_lock:
            return self.thread_rollout.get(thread_id)

    def run_turn(self, thread_id, prompt, progress_token, call_rid, call_threads,
                 cancelled_check=None):
        def is_cancelled():
            return (call_rid is not None and cancelled_check is not None
                    and cancelled_check(call_rid))

        waiter = {"event": threading.Event(), "turn": None, "turn_id": None,
                  "error": None, "progress_token": progress_token,
                  "last_item": None, "start_monotonic": time.monotonic()}
        with self.thread_turn_locks_guard:
            turn_lock = self.thread_turn_locks.setdefault(thread_id, threading.Lock())
        turn_lock.acquire()
        try:
            if is_cancelled():
                self.journal("turn_skipped_cancelled", threadId=thread_id)
                return None, "cancelled before the turn started"
            with self.state_lock:
                self.turn_waiters[thread_id] = waiter
            try:
                try:
                    start_result = self.request(
                        "turn/start",
                        {"threadId": thread_id,
                         "input": [{"type": "text", "text": prompt}]},
                        timeout=TURN_START_TIMEOUT_SEC,
                    )
                except (BackendRpcError, BackendTimeout) as exc:
                    return None, str(exc)
                turn_id = None
                if isinstance(start_result, dict):
                    turn = start_result.get("turn")
                    if isinstance(turn, dict):
                        turn_id = turn.get("id")
                with self.state_lock:
                    waiter["turn_id"] = turn_id
                    if turn_id is not None:
                        self.active_turn[thread_id] = turn_id
                    if call_rid is not None:
                        call_threads[call_rid] = (thread_id, turn_id)
                if is_cancelled():
                    self.journal("interrupt_after_start_cancelled",
                                 threadId=thread_id)
                    if turn_id is not None:
                        self.interrupt(thread_id, turn_id)
                    return None, "cancelled after the turn started"
                if progress_token is not None:
                    self.progress_cb(progress_token, "turn started")
                cap = turn_timeout_sec()
                heartbeat_last = time.monotonic()
                while not waiter["event"].wait(timeout=5):
                    with self.state_lock:
                        proc = self.proc
                    if proc is None or proc.poll() is not None:
                        code = proc.poll() if proc is not None else None
                        return None, (
                            "codex backend child exited (code %r) before the "
                            "turn completed" % (code,)
                        )
                    now = time.monotonic()
                    if cap > 0 and now - waiter["start_monotonic"] >= cap:
                        self.journal("turn_timeout", threadId=thread_id,
                                     timeout_sec=cap)
                        current_turn_id = waiter.get("turn_id")
                        outcome = "confirmed"
                        if current_turn_id is not None:
                            outcome = self.interrupt_or_terminate(
                                thread_id, current_turn_id,
                            )
                        if waiter["error"] is None:
                            if outcome == "confirmed":
                                waiter["error"] = (
                                    "codex_mcp_shim: turn exceeded the %ds "
                                    "wall-clock cap (%s) and was interrupted"
                                    % (cap, TURN_TIMEOUT_ENV_VAR)
                                )
                            elif outcome == "interrupt_failed":
                                waiter["error"] = (
                                    "codex_mcp_shim: turn exceeded the %ds "
                                    "wall-clock cap (%s); the interrupt "
                                    "request itself failed so the codex "
                                    "backend was terminated"
                                    % (cap, TURN_TIMEOUT_ENV_VAR)
                                )
                            else:
                                waiter["error"] = (
                                    "codex_mcp_shim: turn exceeded the %ds "
                                    "wall-clock cap (%s); the interrupt did "
                                    "not complete in time so the codex "
                                    "backend was terminated"
                                    % (cap, TURN_TIMEOUT_ENV_VAR)
                                )
                        waiter["event"].set()
                        break
                    if progress_token is not None and \
                            now - heartbeat_last >= heartbeat_interval_sec():
                        elapsed = int(now - waiter["start_monotonic"])
                        last_item = waiter.get("last_item") or "no activity"
                        self.progress_cb(
                            progress_token,
                            "elapsed %ds, last: %s" % (elapsed, last_item),
                        )
                        heartbeat_last = now
            finally:
                with self.state_lock:
                    if self.turn_waiters.get(thread_id) is waiter:
                        self.turn_waiters.pop(thread_id, None)
                    self.active_turn.pop(thread_id, None)
                    if call_rid is not None:
                        call_threads.pop(call_rid, None)
        finally:
            turn_lock.release()
        if waiter["error"] is not None:
            return None, waiter["error"]
        turn = waiter["turn"]
        status = turn.get("status") if isinstance(turn, dict) else None
        if status == "completed":
            return extract_final_text(turn), None
        err = extract_turn_error(turn) or ("turn ended with status %r" % status)
        return None, err

    def interrupt(self, thread_id, turn_id):
        try:
            self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn_id},
                         timeout=INTERRUPT_TIMEOUT_SEC)
            self.journal("interrupt_sent", threadId=thread_id)
            return True
        except (BackendRpcError, BackendTimeout) as exc:
            self.journal("interrupt_failed", threadId=thread_id, error=str(exc))
            return False

    def terminate(self, reason):
        with self.state_lock:
            proc = self.proc
            self.proc = None
            self.initialized = False
        self.journal("backend_terminated", reason=reason)
        _terminate_child(proc)

    def interrupt_or_terminate(self, thread_id, turn_id, grace_sec=None):
        if grace_sec is None:
            grace_sec = interrupt_grace_sec()
        if not self.interrupt(thread_id, turn_id):
            self.terminate("interrupt_rpc_failed:%s" % thread_id)
            return "interrupt_failed"
        deadline = time.monotonic() + grace_sec
        while time.monotonic() < deadline:
            with self.state_lock:
                waiter = self.turn_waiters.get(thread_id)
                proc = self.proc
            if waiter is None or waiter["event"].is_set():
                return "confirmed"
            if proc is None or proc.poll() is not None:
                return "confirmed"
            waiter["event"].wait(timeout=0.2)
        with self.state_lock:
            still_waiting = thread_id in self.turn_waiters
        if still_waiting:
            self.journal("interrupt_not_confirmed", threadId=thread_id)
            self.terminate("interrupt_no_confirmation:%s" % thread_id)
            return "no_confirmation"
        return "confirmed"

    def _handle_server_request(self, msg):
        method = msg.get("method")
        rid = msg.get("id")
        self.journal("server_request", method=method)
        lowered = method.lower() if isinstance(method, str) else ""
        if method in ("execCommandApproval", "applyPatchApproval"):
            self._write({
                "id": rid,
                "result": {"decision": {"denied": {
                    "rejection": "cbox-codex-shim: approvals are disabled by "
                                 "policy (sandbox=danger-full-access, "
                                 "approvalPolicy=never)"
                }}},
            })
            return
        if "approval" in lowered or "elicitation" in lowered or \
                lowered.endswith("requestuserinput"):
            self._write({"id": rid, "result": {"decision": "decline"}})
            return
        self._write({
            "id": rid,
            "error": {"code": -32601,
                      "message": "cbox-codex-shim: unsupported server "
                                 "request %s" % method},
        })

    def _handle_notification(self, method, params):
        if method == "turn/completed":
            tid = params.get("threadId")
            turn = params.get("turn")
            with self.state_lock:
                waiter = self.turn_waiters.get(tid)
            if waiter is not None:
                expected = waiter.get("turn_id")
                got_id = turn.get("id") if isinstance(turn, dict) else None
                if expected is None or got_id is None or got_id == expected:
                    waiter["turn"] = turn
                    waiter["event"].set()
            return
        if method == "turn/started":
            tid = params.get("threadId")
            turn = params.get("turn")
            if isinstance(turn, dict) and isinstance(turn.get("id"), str):
                with self.state_lock:
                    self.active_turn[tid] = turn["id"]
            return
        if method in ("item/started", "item/completed"):
            item = params.get("item")
            if not isinstance(item, dict):
                return
            tid = params.get("threadId")
            with self.state_lock:
                waiter = self.turn_waiters.get(tid)
            token = None
            if waiter is not None:
                itype = item.get("type")
                if isinstance(itype, str):
                    waiter["last_item"] = itype
                token = waiter.get("progress_token")
            text = item_progress_text(method, item)
            if text is not None and token is not None:
                self.progress_cb(token, text)
            return

    def _on_child_exit(self):
        with self.state_lock:
            pend = list(self.pending.items())
            self.pending = {}
            waiters = list(self.turn_waiters.items())
            proc = self.proc
        exit_code = proc.poll() if proc is not None else None
        message = "codex backend child exited (code %r)" % (exit_code,)
        for rid, (ev, slot) in pend:
            slot["error"] = {"code": -32000, "message": message}
            ev.set()
        for tid, waiter in waiters:
            if waiter["event"].is_set():
                continue
            waiter["error"] = message
            waiter["event"].set()
        self.journal("child_exit", code=exit_code)

    def _read_loop(self):
        try:
            for raw in read_lines(self.proc.stdout, MAX_BACKEND_LINE):
                if not raw.strip():
                    continue
                try:
                    msg = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue
                if "method" in msg and "id" in msg:
                    self._handle_server_request(msg)
                    continue
                if "method" not in msg and "id" in msg:
                    rid = msg["id"]
                    with self.state_lock:
                        entry = self.pending.get(rid)
                    if entry is not None:
                        ev, slot = entry
                        if "error" in msg:
                            slot["error"] = msg["error"]
                        else:
                            slot["result"] = msg.get("result")
                        ev.set()
                    continue
                method = msg.get("method")
                params = msg.get("params")
                if not isinstance(params, dict):
                    params = {}
                self._handle_notification(method, params)
        except OversizedLineError as exc:
            with self.state_lock:
                pend = list(self.pending.items())
                self.pending = {}
                waiters = list(self.turn_waiters.items())
            note = (
                "codex_mcp_shim: backend message exceeded the size limit of "
                "%d bytes; failing all in-flight calls" % exc.limit
            )
            self.journal(
                "oversized_backend_line", limit=exc.limit,
            )
            try:
                sys.stderr.write(note + "\n")
            except Exception:
                pass
            for rid, (ev, slot) in pend:
                slot["error"] = {"code": -32000, "message": note}
                ev.set()
            for tid, waiter in waiters:
                waiter["error"] = note
                waiter["event"].set()
            with self.state_lock:
                proc = self.proc
                self.initialized = False
            if proc is not None:
                try:
                    proc.kill()
                except Exception:
                    pass
        finally:
            self._on_child_exit()


class Relay:
    def __init__(
        self,
        tier,
        model,
        effort,
        progress_on,
        child_argv,
        log_path,
        depth_stub,
        kernel_text,
    ):
        self.tier = tier
        self.model = model
        self.effort = effort
        self.progress_on = progress_on
        self.log_path = log_path
        self.depth_stub = depth_stub
        self.kernel_text = kernel_text
        self.stdout_lock = threading.Lock()
        self.progress_lock = threading.Lock()
        self.progress_seq = {}
        self.call_lock = threading.Lock()
        self.call_threads = {}
        self.cancel_lock = threading.Lock()
        self.cancelled_ids = collections.OrderedDict()
        self.inflight_lock = threading.Lock()
        self.inflight_calls = 0
        self.backend = CodexBackend(
            child_argv, tier, self.journal, self.emit_progress,
        )

    def mark_cancelled(self, rid):
        with self.cancel_lock:
            self.cancelled_ids[rid] = True
            self.cancelled_ids.move_to_end(rid)
            while len(self.cancelled_ids) > MAX_CANCELLED_IDS:
                self.cancelled_ids.popitem(last=False)

    def was_cancelled(self, rid):
        if rid is None:
            return False
        with self.cancel_lock:
            return rid in self.cancelled_ids

    def _inflight_enter(self):
        with self.inflight_lock:
            self.inflight_calls += 1

    def _inflight_exit(self):
        with self.inflight_lock:
            self.inflight_calls = max(0, self.inflight_calls - 1)

    def _inflight_count(self):
        with self.inflight_lock:
            return self.inflight_calls

    def _thread_pointer_text(self, thread_id, rollout_hint=None):
        if not isinstance(thread_id, str) or not thread_id:
            return ""
        rollout = rollout_hint or self.backend.cached_rollout(thread_id)
        if not rollout:
            rollout = find_rollout_path_by_thread_id(thread_id)
        if rollout:
            return "threadId: %s; rollout: %s" % (thread_id, rollout)
        return "threadId: %s" % thread_id

    def _append_pointer(self, text, thread_id, rollout_hint=None):
        pointer = self._thread_pointer_text(thread_id, rollout_hint)
        if not pointer:
            return text
        return "%s\n\n[%s]" % (text, pointer)

    def _shutdown(self, reason):
        self.journal("shutdown", reason=reason)
        with self.backend.state_lock:
            active = list(self.backend.active_turn.items())
            proc = self.backend.proc
        for tid, turn_id in active:
            try:
                self.backend.interrupt(tid, turn_id)
            except Exception:
                pass
        _terminate_child(proc)

    def journal(self, event, **fields):
        if not self.log_path:
            return
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event}
        rec.update(fields)
        try:
            line = json.dumps(rec, ensure_ascii=True, default=str)
        except (TypeError, ValueError):
            line = json.dumps({"ts": rec["ts"], "event": event}, ensure_ascii=True)
        if len(line) > MAX_JOURNAL:
            line = line[:MAX_JOURNAL] + "...TRUNCATED"
        try:
            os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
            fd = os.open(
                self.log_path,
                os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW,
                0o600,
            )
            with os.fdopen(fd, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass

    def send(self, obj):
        line = (json.dumps(obj) + "\n").encode()
        with self.stdout_lock:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()

    def reply(self, rid, result):
        self.send({"jsonrpc": "2.0", "id": rid, "result": result})

    def reply_error(self, rid, code, message):
        self.send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})

    def emit_progress(self, token, message):
        if token is None or not self.progress_on:
            return
        if isinstance(token, str) and len(token) > MAX_PROGRESS_TOKEN_LEN:
            return
        with self.progress_lock:
            seq = self.progress_seq.get(token, 0) + 1
            self.progress_seq[token] = seq
            while len(self.progress_seq) > MAX_PROGRESS_TOKENS:
                self.progress_seq.pop(next(iter(self.progress_seq)))
        self.send({
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": {"progressToken": token, "progress": seq,
                       "message": sanitize(message)},
        })

    def handle_initialize(self, msg):
        rid = msg.get("id")
        params = msg.get("params")
        proto = DEFAULT_PROTOCOL
        if isinstance(params, dict):
            candidate = params.get("protocolVersion")
            if isinstance(candidate, str) and candidate:
                proto = candidate
        self.reply(rid, {
            "protocolVersion": proto,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "codex-%s" % self.tier, "version": "1"},
        })

    def handle_tools_list(self, rid):
        if self.depth_stub:
            self.reply(rid, {"tools": []})
            return
        self.reply(rid, {"tools": [self._codex_tool(), self._codex_reply_tool()]})

    def _codex_tool(self):
        return {
            "name": "codex",
            "description": (
                "Delegate one task to a codex agent (tier-pinned model and "
                "reasoning effort). Requires an explicit absolute cwd inside "
                "the allowed scope and a git work-tree."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string",
                               "description": "Task instructions for codex."},
                    "cwd": {"type": "string",
                            "description": "Absolute working directory, "
                                           "required, must be a git work-tree "
                                           "inside the allowed scope."},
                    "model": {"type": "string",
                              "description": "Ignored - the tier pins the "
                                             "model."},
                    "sandbox": {"type": "string",
                                "enum": ["read-only", "workspace-write",
                                         "danger-full-access"]},
                    "approval-policy": {"type": "string",
                                        "enum": ["untrusted", "on-request",
                                                 "never"]},
                    "config": {"type": "object",
                               "description": "Free-form config.toml-style "
                                              "overrides; model/provider/"
                                              "sandbox/approval/instructions "
                                              "keys are rejected by policy."},
                    "profile": {"type": "string",
                                "description": "Reserved - rejected by "
                                               "policy."},
                },
                "required": ["prompt"],
            },
        }

    def _codex_reply_tool(self):
        return {
            "name": "codex-reply",
            "description": "Continue an existing codex thread started by "
                            "this relay.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string"},
                    "threadId": {"type": "string"},
                    "conversationId": {"type": "string",
                                       "description": "Alias for threadId."},
                },
                "required": ["prompt"],
            },
        }

    def _child_env(self):
        env = {"CBOX_DELEGATION_DEPTH": "1", "CBOX_MCP_DEPTH": "1"}
        return env

    def handle_tools_call(self, msg):
        rid = msg.get("id")
        params = msg.get("params")
        if not isinstance(params, dict):
            if rid is not None:
                self.reply_error(rid, -32000,
                                  "codex_mcp_shim: tools/call params must be an object")
            return
        name = params.get("name")
        args = params.get("arguments")
        if args is None:
            args = {}
        if not isinstance(args, dict):
            if rid is not None:
                self.reply_error(rid, -32000,
                                  "codex_mcp_shim: tools/call arguments must be an object")
            return
        meta = params.get("_meta")
        token = None
        if isinstance(meta, dict):
            candidate = meta.get("progressToken")
            if valid_progress_token(candidate):
                token = candidate

        if self.depth_stub:
            if rid is not None:
                self.reply_error(rid, -32601, DEPTH_ERROR)
            return

        if rid is not None and self.was_cancelled(rid):
            self.journal("call_skipped_cancelled", requestId=rid)
            return

        self._inflight_enter()
        try:
            if name == "codex":
                self._call_codex(rid, args, token)
            elif name == "codex-reply":
                self._call_codex_reply(rid, args, token)
            else:
                if rid is not None:
                    self.reply_error(rid, -32602, "unknown tool: %s" % name)
        finally:
            self._inflight_exit()

    def _call_codex(self, rid, args, token):
        cwd = args.get("cwd")
        scope_err = check_cwd_scope_and_git(cwd)
        if scope_err is not None:
            shim_audit(self.tier, "deny", scope_err, cwd)
            if rid is not None:
                self.reply_error(rid, -32000, scope_err)
            return
        shim_audit(self.tier, "allow", None, cwd)

        cfg = args.get("config")
        if cfg is not None and not isinstance(cfg, dict):
            if rid is not None:
                self.reply_error(
                    rid, -32000,
                    "codex_mcp_shim: tools/call arguments.config must be an object",
                )
            return
        policy_err = policy_check_args(args, cfg)
        if policy_err is not None:
            if rid is not None:
                self.reply_error(rid, -32000, policy_err)
            return

        prompt = args.get("prompt")
        if not isinstance(prompt, str) or not prompt:
            if rid is not None:
                self.reply_error(rid, -32000,
                                  "codex_mcp_shim: prompt must be a non-empty string")
            return

        real_cwd = os.path.realpath(cwd)
        merged_cfg = dict(cfg) if isinstance(cfg, dict) else {}
        merged_cfg["model_reasoning_effort"] = self.effort

        sandbox = args.get("sandbox")
        approval = args.get("approval-policy")
        if in_container():
            sandbox = "danger-full-access"
            approval = "never"

        thread_params = {
            "model": self.model,
            "cwd": real_cwd,
            "config": merged_cfg,
            "developerInstructions": self.kernel_text,
        }
        if sandbox is not None:
            thread_params["sandbox"] = sandbox
        if approval is not None:
            thread_params["approvalPolicy"] = approval

        try:
            self.backend.ensure_started(self._child_env())
            start_result = self.backend.request(
                "thread/start", thread_params, timeout=THREAD_START_TIMEOUT_SEC,
            )
        except (BackendRpcError, BackendTimeout) as exc:
            if rid is not None:
                self.reply_error(rid, -32000, "codex_mcp_shim: %s" % exc)
            return

        thread = start_result.get("thread") if isinstance(start_result, dict) else None
        thread_id = thread.get("id") if isinstance(thread, dict) else None
        actual_model = start_result.get("model") if isinstance(start_result, dict) else None
        if not isinstance(thread_id, str) or not thread_id:
            if rid is not None:
                self.reply_error(rid, -32000,
                                  "codex_mcp_shim: backend thread/start returned no thread id")
            return
        rollout_hint = _rollout_field_from_result(start_result)
        if actual_model != self.model:
            if rid is not None:
                msg = (
                    "codex_mcp_shim: model pin mismatch (tier=%s got=%s) - "
                    "refusing to use this thread" % (self.model, actual_model)
                )
                self.reply_error(
                    rid, -32000,
                    self._append_pointer(msg, thread_id, rollout_hint),
                )
            return

        self.backend.mark_thread_live(thread_id, real_cwd, rollout_hint)
        self._finish_turn(rid, thread_id, prompt, token)

    def _call_codex_reply(self, rid, args, token):
        tid = args.get("threadId")
        if not isinstance(tid, str) or not tid:
            tid = args.get("conversationId")
        if not isinstance(tid, str) or not tid:
            if rid is not None:
                self.reply_error(
                    rid, -32000,
                    "thread unknown to this relay - start a new codex call",
                )
            return
        disk_rollout_hint = None
        disk_cwd = None
        if not self.backend.known_thread(tid):
            disk_rollout_hint = find_rollout_path_by_thread_id(tid)
            if disk_rollout_hint is None:
                if rid is not None:
                    self.reply_error(
                        rid, -32000,
                        "thread unknown to this relay - start a new codex call",
                    )
                return
            raw_cwd = rollout_cwd(disk_rollout_hint)
            if not raw_cwd:
                shim_audit(self.tier, "deny",
                           "disk rollout has no readable cwd", None,
                           thread_id=tid)
                if rid is not None:
                    self.reply_error(
                        rid, -32000,
                        "codex_mcp_shim: the rollout for thread %s on disk "
                        "has no readable cwd - refusing to resume"
                        % sanitize(tid),
                    )
                return
            scope_err = check_cwd_scope_and_git(raw_cwd)
            if scope_err is not None:
                shim_audit(self.tier, "deny", scope_err, raw_cwd, thread_id=tid)
                if rid is not None:
                    self.reply_error(rid, -32000, scope_err)
                return
            disk_cwd = os.path.realpath(raw_cwd)
            shim_audit(self.tier, "allow", None, disk_cwd, thread_id=tid)
        prompt = args.get("prompt")
        if not isinstance(prompt, str) or not prompt:
            if rid is not None:
                self.reply_error(rid, -32000,
                                  "codex_mcp_shim: prompt must be a non-empty string")
            return

        try:
            self.backend.ensure_started(self._child_env())
            if not self.backend.thread_is_live(tid):
                resume_params = {
                    "threadId": tid,
                    "model": self.model,
                    "config": {"model_reasoning_effort": self.effort},
                }
                cwd = disk_cwd if disk_cwd is not None else self.backend.cached_cwd(tid)
                if cwd is not None:
                    resume_params["cwd"] = cwd
                if in_container():
                    resume_params["sandbox"] = "danger-full-access"
                    resume_params["approvalPolicy"] = "never"
                resume_result = self.backend.request(
                    "thread/resume", resume_params, timeout=THREAD_RESUME_TIMEOUT_SEC,
                )
                resume_rollout_hint = (
                    _rollout_field_from_result(resume_result) or disk_rollout_hint
                )
                if not isinstance(resume_result, dict) \
                        or resume_result.get("model") != self.model:
                    if rid is not None:
                        msg = (
                            "codex_mcp_shim: model pin mismatch (tier=%s got=%s) "
                            "- refusing to use this thread" % (
                                self.model,
                                resume_result.get("model")
                                if isinstance(resume_result, dict) else None,
                            )
                        )
                        self.reply_error(
                            rid, -32000,
                            self._append_pointer(msg, tid, resume_rollout_hint),
                        )
                    return
                self.backend.mark_thread_live(tid, cwd, resume_rollout_hint)
        except (BackendRpcError, BackendTimeout) as exc:
            if rid is not None:
                self.reply_error(rid, -32000, "codex_mcp_shim: %s" % exc)
            return

        self._finish_turn(rid, tid, prompt, token)

    def _finish_turn(self, rid, thread_id, prompt, token):
        if rid is not None and self.was_cancelled(rid):
            self.journal("finish_turn_skipped_cancelled", threadId=thread_id)
            return
        with self.call_lock:
            while len(self.call_threads) >= MAX_CALLS:
                self.call_threads.pop(next(iter(self.call_threads)))
        try:
            started = time.time()
            text, err = self.backend.run_turn(
                thread_id, prompt, token, rid, self.call_threads,
                cancelled_check=self.was_cancelled,
            )
            duration = time.time() - started
            cancelled_after = rid is not None and self.was_cancelled(rid)
            outcome = "cancelled" if cancelled_after else _classify_call_outcome(err)
            shim_audit(
                self.tier, "allow", err[:128] if err else None,
                self.backend.cached_cwd(thread_id), thread_id=thread_id,
                outcome=outcome, duration_sec=duration,
            )
            if rid is None or cancelled_after:
                return
            if err is not None:
                self.reply(rid, {
                    "content": [{"type": "text",
                                 "text": self._append_pointer(err, thread_id)}],
                    "isError": True,
                })
                return
            self.reply(rid, {
                "content": [{"type": "text",
                             "text": self._append_pointer(text, thread_id)}],
                "structuredContent": {"threadId": thread_id, "content": text},
            })
        finally:
            if token is not None:
                with self.progress_lock:
                    self.progress_seq.pop(token, None)

    def handle_cancel(self, msg):
        params = msg.get("params")
        if not isinstance(params, dict):
            return
        crid = params.get("requestId")
        if not isinstance(crid, (str, int)) or isinstance(crid, bool):
            return
        self.mark_cancelled(crid)
        with self.call_lock:
            entry = self.call_threads.get(crid)
        self.journal("cancelled", requestId=crid)
        if entry is None:
            return
        thread_id, turn_id = entry
        if turn_id is None:
            return
        threading.Thread(
            target=self.backend.interrupt_or_terminate,
            args=(thread_id, turn_id), daemon=True,
        ).start()

    def dispatch(self, msg):
        method = msg.get("method")
        rid = msg.get("id")
        if method == "initialize":
            self.handle_initialize(msg)
        elif method in ("notifications/initialized", "initialized"):
            return
        elif method == "ping":
            self.reply(rid, {})
        elif method == "tools/list":
            self.handle_tools_list(rid)
        elif method == "tools/call":
            def worker(m=msg):
                try:
                    self.handle_tools_call(m)
                except Exception as exc:
                    if rid is not None:
                        self.reply_error(
                            rid, -32603,
                            "internal error: %s: %s" % (type(exc).__name__, exc),
                        )

            threading.Thread(target=worker, daemon=True).start()
        elif method == "notifications/cancelled":
            self.handle_cancel(msg)
        elif rid is not None:
            self.reply_error(rid, -32601, "method not found: %s" % method)

    def run(self):
        for raw in read_lines(sys.stdin.buffer, MAX_LINE):
            if not raw.strip():
                continue
            try:
                msg = json.loads(raw)
            except (OversizedLineError, ValueError) as exc:
                if isinstance(exc, OversizedLineError):
                    try:
                        sys.stderr.write(
                            "codex_mcp_shim: MCP stdin line exceeded the "
                            "%d byte limit; failing\n" % exc.limit,
                        )
                    except Exception:
                        pass
                self.send({"jsonrpc": "2.0", "id": None,
                           "error": {"code": -32700, "message": "parse error"}})
                continue
            if not isinstance(msg, dict):
                continue
            try:
                self.dispatch(msg)
            except Exception as exc:
                rid = msg.get("id")
                if rid is not None:
                    self.reply_error(rid, -32603,
                                      "internal error: %s" % type(exc).__name__)
        deadline = time.monotonic() + STDIN_EOF_GRACE_SEC
        while self._inflight_count() > 0 and time.monotonic() < deadline:
            time.sleep(0.1)
        self._shutdown("stdin_eof")
        return 0


def _install_signal_handlers(relay):
    def handler(signum, frame):
        try:
            relay._shutdown("signal:%d" % signum)
        finally:
            os._exit(128 + signum)

    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGHUP, handler)


def main():
    ns, child_argv = parse_args(sys.argv[1:])
    log_path = os.environ.get("CBOX_CODEX_SHIM_LOG", "")
    depth = os.environ.get("CBOX_DELEGATION_DEPTH") or os.environ.get("CBOX_MCP_DEPTH")
    depth_stub = bool(depth)
    kernel_text = load_kernel()
    relay = Relay(
        tier=ns.tier,
        model=ns.model,
        effort=ns.effort,
        progress_on=(ns.progress == "on"),
        child_argv=child_argv,
        log_path=log_path,
        depth_stub=depth_stub,
        kernel_text=kernel_text,
    )
    _install_signal_handlers(relay)
    return relay.run()


if __name__ == "__main__":
    sys.exit(main())
