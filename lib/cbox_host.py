#!/usr/bin/env python3
import fcntl
import hashlib
import os
import platform
import sys
import time

EX_USAGE = 64
EX_OSERR = 65
EX_CONFLICT = 1
EX_TIMEOUT = 124
EX_NOTFOUND = 127
EX_NOPERM = 126


def _is_darwin():
    return platform.system() == "Darwin"


def sha256_stdin(stream):
    h = hashlib.sha256()
    while True:
        chunk = stream.read(1024 * 1024)
        if not chunk:
            break
        h.update(chunk)
    return h.hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def cmd_sha256(argv):
    if argv:
        path = argv[0]
        try:
            digest = sha256_file(path)
        except OSError as exc:
            sys.stderr.write("cbox_host: sha256: %s: %s\n" % (path, exc.strerror or exc))
            return 1
        sys.stdout.write("%s\n" % digest)
        return 0
    digest = sha256_stdin(sys.stdin.buffer)
    sys.stdout.write("%s\n" % digest)
    return 0


def cmd_flock(argv):
    mode = fcntl.LOCK_EX
    nonblock = False
    timeout = None
    fd_arg = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "-x":
            mode = fcntl.LOCK_EX
        elif a == "-s":
            mode = fcntl.LOCK_SH
        elif a == "-n":
            nonblock = True
        elif a == "-w":
            i += 1
            if i >= len(argv):
                sys.stderr.write("cbox_host: flock: -w requires an argument\n")
                return EX_USAGE
            try:
                timeout = float(argv[i])
            except ValueError:
                sys.stderr.write("cbox_host: flock: invalid -w value: %s\n" % argv[i])
                return EX_USAGE
        elif a.startswith("-"):
            sys.stderr.write("cbox_host: flock: unrecognized option '%s'\n" % a)
            return EX_USAGE
        else:
            if fd_arg is not None:
                sys.stderr.write("cbox_host: flock: unexpected argument '%s'\n" % a)
                return EX_USAGE
            fd_arg = a
        i += 1

    if fd_arg is None:
        sys.stderr.write("cbox_host: flock: not enough arguments\n")
        return EX_USAGE
    try:
        fd = int(fd_arg)
    except ValueError:
        sys.stderr.write("cbox_host: flock: invalid file descriptor: %s\n" % fd_arg)
        return EX_USAGE

    if nonblock:
        try:
            fcntl.flock(fd, mode | fcntl.LOCK_NB)
            return 0
        except OSError as exc:
            if exc.errno in (11, 35):
                return EX_CONFLICT
            sys.stderr.write("cbox_host: flock: %d: %s\n" % (fd, exc.strerror or exc))
            return EX_OSERR
    elif timeout is not None:
        deadline = time.monotonic() + timeout
        poll_interval = 0.05
        while True:
            try:
                fcntl.flock(fd, mode | fcntl.LOCK_NB)
                return 0
            except OSError as exc:
                if exc.errno not in (11, 35):
                    sys.stderr.write("cbox_host: flock: %d: %s\n" % (fd, exc.strerror or exc))
                    return EX_OSERR
            if time.monotonic() >= deadline:
                return EX_CONFLICT
            time.sleep(poll_interval)
    else:
        try:
            fcntl.flock(fd, mode)
            return 0
        except OSError as exc:
            sys.stderr.write("cbox_host: flock: %d: %s\n" % (fd, exc.strerror or exc))
            return EX_OSERR


def _realpath_missing_errno(path):
    try:
        os.stat(path)
        return None
    except OSError as exc:
        return exc.errno


def _strip_trailing_slashes(path):
    if path in ("", "/"):
        return path
    stripped = path.rstrip("/")
    return stripped if stripped else "/"


def _realpath_bare_one(path):
    if path == "":
        return None, "No such file or directory"
    trimmed = _strip_trailing_slashes(path)
    had_trailing_slash = trimmed != path
    errno_full = _realpath_missing_errno(trimmed)
    if errno_full is None:
        resolved = os.path.realpath(trimmed)
        if had_trailing_slash and not os.path.isdir(resolved):
            return None, os.strerror(20)
        return resolved, None
    parent_dir, leaf_name = os.path.split(trimmed)
    if leaf_name == "":
        return None, os.strerror(errno_full)
    if errno_full != 2:
        return None, os.strerror(errno_full)
    if os.path.lexists(trimmed):
        return None, os.strerror(2)
    if parent_dir == "":
        return os.path.realpath(trimmed), None
    errno_parent = _realpath_missing_errno(parent_dir)
    if errno_parent is None:
        return os.path.realpath(trimmed), None
    return None, os.strerror(errno_parent)


def cmd_realpath(argv):
    mode = "bare"
    path = None
    for a in argv:
        if a == "-m":
            mode = "m"
        elif a.startswith("-") and a != "-":
            sys.stderr.write("cbox_host: realpath: unrecognized option '%s'\n" % a)
            return 2
        elif path is None:
            path = a
        else:
            sys.stderr.write("cbox_host: realpath: unexpected argument '%s'\n" % a)
            return 2

    if path is None:
        sys.stderr.write("cbox_host: realpath: missing operand\n")
        return 1

    if mode == "m":
        if path == "":
            sys.stderr.write("cbox_host: realpath: '': No such file or directory\n")
            return 1
        sys.stdout.write("%s\n" % os.path.realpath(path))
        return 0

    resolved, err = _realpath_bare_one(path)
    if err is not None:
        sys.stderr.write("cbox_host: realpath: '%s': %s\n" % (path, err))
        return 1
    sys.stdout.write("%s\n" % resolved)
    return 0


def cmd_timeout(argv):
    import signal
    import subprocess

    if len(argv) < 2:
        sys.stderr.write("cbox_host: timeout: usage: timeout DURATION COMMAND [ARG]...\n")
        return EX_USAGE
    try:
        duration = float(argv[0])
    except ValueError:
        sys.stderr.write("cbox_host: timeout: invalid duration: %s\n" % argv[0])
        return EX_USAGE
    cmd = argv[1:]

    try:
        proc = subprocess.Popen(cmd, start_new_session=True)
    except FileNotFoundError as exc:
        sys.stderr.write(
            "cbox_host: timeout: failed to run command '%s': %s\n" % (cmd[0], exc.strerror or exc)
        )
        return EX_NOTFOUND
    except PermissionError as exc:
        sys.stderr.write(
            "cbox_host: timeout: failed to run command '%s': %s\n" % (cmd[0], exc.strerror or exc)
        )
        return EX_NOPERM
    except OSError as exc:
        sys.stderr.write(
            "cbox_host: timeout: failed to run command '%s': %s\n" % (cmd[0], exc.strerror or exc)
        )
        return EX_OSERR

    try:
        rc = proc.wait(timeout=duration)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        return EX_TIMEOUT

    if rc < 0:
        return 128 - rc
    return rc


def _stat_field(argv, field):
    path = None
    for a in argv:
        if a == "--":
            continue
        if path is None:
            path = a
        else:
            sys.stderr.write("cbox_host: stat: unexpected argument '%s'\n" % a)
            return None, 2
    if path is None:
        sys.stderr.write("cbox_host: stat: missing operand\n")
        return None, 1
    try:
        st = os.lstat(path)
    except OSError as exc:
        sys.stderr.write("cbox_host: stat: cannot stat '%s': %s\n" % (path, exc.strerror or exc))
        return None, 1
    if field == "u":
        return st.st_uid, 0
    return int(st.st_mtime), 0


def cmd_stat_uid(argv):
    value, rc = _stat_field(argv, "u")
    if rc != 0:
        return rc
    sys.stdout.write("%d\n" % value)
    return 0


def cmd_stat_mtime(argv):
    value, rc = _stat_field(argv, "Y")
    if rc != 0:
        return rc
    sys.stdout.write("%d\n" % value)
    return 0


def cmd_ismount(argv):
    path = None
    for a in argv:
        if path is None:
            path = a
        else:
            sys.stderr.write("cbox_host: ismount: unexpected argument '%s'\n" % a)
            return EX_USAGE
    if path is None:
        sys.stderr.write("cbox_host: ismount: missing operand\n")
        return EX_USAGE
    try:
        os.stat(path)
    except OSError as exc:
        sys.stderr.write("cbox_host: ismount: %s: %s\n" % (path, exc.strerror or exc))
        return 1
    resolved = os.path.realpath(path)
    if os.path.ismount(resolved):
        return 0
    return 32


COMMANDS = {
    "sha256": cmd_sha256,
    "flock": cmd_flock,
    "realpath": cmd_realpath,
    "timeout": cmd_timeout,
    "stat_uid": cmd_stat_uid,
    "stat_mtime": cmd_stat_mtime,
    "ismount": cmd_ismount,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        sys.stderr.write("usage: cbox_host.py <%s> [args...]\n" % "|".join(sorted(COMMANDS)))
        return 2
    return COMMANDS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
