#!/usr/bin/env python3
import fcntl
import json
import os
import pty as pty_module
import re
import selectors
import signal
import stat
import struct
import subprocess
import sys
import termios
import time
import unicodedata


SESSION_RE = re.compile(r"^cbox-[a-z0-9]{1,32}-[a-f0-9]{8,32}$")
ENGINE_RE = re.compile(r"^(claude|codex|hermes)$")
TIER_VALUES = ("disabled", "viewer", "full-attach")

ACCESS_FILE = os.environ.get("CBOX_SSHD_ACCESS_FILE", "/etc/cbox-sshd/access.level")
WINDOW_FILE = os.environ.get("CBOX_SSHD_WINDOW_FILE", "/etc/cbox-sshd/access.window")
AUDIT_PATH = os.environ.get("CBOX_SSHD_AUDIT_PATH", "/var/log/cbox-sshd/audit.jsonl")

COMMAND_RE = re.compile(
    r"^(?:list|attach [a-z0-9][a-z0-9_.-]{0,143}|spawn [a-z0-9][a-z0-9_.-]{0,63})$"
)


def safe_text(raw):
    value = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw)
    return "".join(
        "?" if (ord(c) < 32 and c not in "\n\t") or 127 <= ord(c) <= 159 or unicodedata.category(c) == "Cf"
        else c
        for c in value
    )


class AuditUnavailable(Exception):
    pass


def audit(record):
    record = dict(record)
    record["at"] = int(time.time())
    raw = (json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")
    audit_dir = os.path.dirname(AUDIT_PATH)
    try:
        os.makedirs(audit_dir, mode=0o700, exist_ok=True)
        fd = os.open(AUDIT_PATH, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as exc:
        raise AuditUnavailable(str(exc))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise AuditUnavailable("audit path is not a regular file")
        offset = 0
        while offset < len(raw):
            offset += os.write(fd, raw[offset:])
        os.fsync(fd)
    except OSError as exc:
        raise AuditUnavailable(str(exc))
    finally:
        os.close(fd)


def connection_identity():
    conn = os.environ.get("SSH_CONNECTION", "")
    parts = conn.split()
    addr = parts[0] if parts else ""
    return "address", addr or "unknown"


def resolve_tier():
    try:
        st = os.lstat(ACCESS_FILE)
    except OSError:
        return "disabled"
    if not stat.S_ISREG(st.st_mode):
        return "disabled"
    try:
        with open(ACCESS_FILE, "r", encoding="ascii") as fh:
            raw = fh.readline().strip()
    except OSError:
        return "disabled"
    if raw not in TIER_VALUES:
        return "disabled"
    return raw


def window_open():
    try:
        st = os.lstat(WINDOW_FILE)
    except OSError:
        return True
    if not stat.S_ISREG(st.st_mode):
        return False
    try:
        with open(WINDOW_FILE, "r", encoding="ascii") as fh:
            raw = fh.readline().strip()
    except OSError:
        return False
    if raw == "":
        return True
    try:
        deadline = int(raw)
    except ValueError:
        return False
    return int(time.time()) < deadline


def parse_command(raw):
    if raw is None:
        raise ValueError("no command supplied")
    if not COMMAND_RE.match(raw):
        raise ValueError("command does not match the allow-list")
    parts = raw.split(" ", 1)
    op = parts[0]
    if op == "list":
        return "list", None
    if op == "attach":
        session = parts[1]
        if not SESSION_RE.match(session):
            raise ValueError("invalid session name")
        return "attach", session
    if op == "spawn":
        engine = parts[1]
        if not ENGINE_RE.match(engine):
            raise ValueError("invalid engine")
        return "spawn", engine
    raise ValueError("unsupported operation")


def build_attach_argv(tier, session):
    if tier == "viewer":
        return ["tmux", "attach-session", "-r", "-f", "read-only,ignore-size", "-t", session]
    if tier == "full-attach":
        return ["tmux", "attach-session", "-t", session]
    raise PermissionError("sshd access is disabled for this container")


def new_session_name(engine):
    hex_part = os.urandom(8).hex()
    return "cbox-%s-%s" % (engine, hex_part)


def run_list():
    fmt = "#{session_name}\t#{session_created}\t#{session_path}"
    proc = subprocess.run(
        ["tmux", "list-sessions", "-F", fmt],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    out = safe_text(proc.stdout)
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3 or not SESSION_RE.match(parts[0]):
            continue
        sys.stdout.write("%s\t%s\t%s\n" % (parts[0], parts[1], parts[2]))
    return 0


def stop_process(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        proc.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def term_size(fd):
    try:
        raw = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
        rows, cols, _, _ = struct.unpack("HHHH", raw)
        if rows and cols:
            return rows, cols
    except OSError:
        pass
    return 24, 80


def run_attach(argv, tier):
    master_fd, slave_fd = pty_module.openpty()
    stdin_isatty = sys.stdin.isatty()
    if stdin_isatty:
        rows, cols = term_size(sys.stdin.fileno())
        fcntl.ioctl(master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    proc = subprocess.Popen(
        argv,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        preexec_fn=os.setsid,
        close_fds=True,
    )
    os.close(slave_fd)

    def relay_resize(signum, frame):
        if not stdin_isatty:
            return
        rows, cols = term_size(sys.stdin.fileno())
        try:
            fcntl.ioctl(master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            pass
        try:
            os.killpg(proc.pid, signal.SIGWINCH)
        except OSError:
            pass

    old_handler = signal.signal(signal.SIGWINCH, relay_resize)

    sel = selectors.DefaultSelector()
    sel.register(master_fd, selectors.EVENT_READ, "pty")
    sel.register(sys.stdin.fileno(), selectors.EVENT_READ, "stdin")
    rc = 1
    try:
        while True:
            if proc.poll() is not None:
                rc = proc.returncode
                break
            for key, _ in sel.select(timeout=0.5):
                if key.data == "pty":
                    try:
                        data = os.read(master_fd, 65536)
                    except OSError:
                        data = b""
                    if not data:
                        stop_process(proc)
                        rc = proc.returncode if proc.returncode is not None else 1
                        break
                    os.write(sys.stdout.fileno(), data)
                else:
                    try:
                        data = os.read(sys.stdin.fileno(), 65536)
                    except OSError:
                        data = b""
                    if not data:
                        sel.unregister(sys.stdin.fileno())
                        continue
                    if tier == "full-attach":
                        os.write(master_fd, data)
    finally:
        signal.signal(signal.SIGWINCH, old_handler)
        stop_process(proc)
        try:
            os.close(master_fd)
        except OSError:
            pass
    return rc


def main():
    id_kind, id_value = connection_identity()
    raw_command = os.environ.get("SSH_ORIGINAL_COMMAND")

    tier = resolve_tier()
    open_window = window_open()

    try:
        op, arg = parse_command(raw_command)
    except ValueError as exc:
        audit({"op": "parse", "outcome": "denied", "reason": safe_text(str(exc))[:200],
               "identityKind": id_kind, "identity": id_value})
        sys.stderr.write("cbox-session-entry: %s\n" % exc)
        return 1

    if tier == "disabled" or not open_window:
        reason = "access level is disabled" if tier == "disabled" else "access window is closed"
        audit({"op": op, "outcome": "denied", "reason": reason, "tier": tier,
               "identityKind": id_kind, "identity": id_value})
        sys.stderr.write("cbox-session-entry: %s\n" % reason)
        return 1

    if op == "list":
        audit({"op": "list", "outcome": "ok", "tier": tier,
               "identityKind": id_kind, "identity": id_value})
        return run_list()

    if op == "attach":
        session = arg
        try:
            argv = build_attach_argv(tier, session)
        except PermissionError as exc:
            audit({"op": "attach", "session": session, "outcome": "denied", "reason": safe_text(str(exc))[:200],
                   "tier": tier, "identityKind": id_kind, "identity": id_value})
            sys.stderr.write("cbox-session-entry: %s\n" % exc)
            return 1
        audit({"op": "attach", "session": session, "outcome": "start", "tier": tier,
               "identityKind": id_kind, "identity": id_value})
        rc = run_attach(argv, tier)
        audit({"op": "attach", "session": session, "outcome": "end", "tier": tier, "rc": rc,
               "identityKind": id_kind, "identity": id_value})
        return rc

    if op == "spawn":
        engine = arg
        if tier != "full-attach":
            audit({"op": "spawn", "engine": engine, "outcome": "denied",
                   "reason": "spawning a new session requires full-attach", "tier": tier,
                   "identityKind": id_kind, "identity": id_value})
            sys.stderr.write("cbox-session-entry: spawning a new session requires full-attach tier\n")
            return 1
        session = new_session_name(engine)
        audit({"op": "spawn", "engine": engine, "session": session, "outcome": "start", "tier": tier,
               "identityKind": id_kind, "identity": id_value})
        inner = "exec tmux new-session -s %s /entrypoint.sh %s" % (session, engine)
        subprocess.Popen(
            ["sh", "-c", inner],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        time.sleep(0.5)
        argv = build_attach_argv(tier, session)
        rc = run_attach(argv, tier)
        audit({"op": "spawn", "engine": engine, "session": session, "outcome": "end", "tier": tier, "rc": rc,
               "identityKind": id_kind, "identity": id_value})
        return rc

    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AuditUnavailable as exc:
        sys.stderr.write(
            "cbox-session-entry: refusing - the access log cannot be written "
            "(%s); a session is never served unmonitored\n" % exc)
        sys.exit(3)
    except Exception as exc:
        sys.stderr.write("cbox-session-entry: %s\n" % exc)
        sys.exit(2)
