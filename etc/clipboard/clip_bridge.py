#!/usr/bin/env python3
import argparse
import os
import shutil
import socket
import struct
import subprocess
import sys
import time

MIME_ALLOWLIST = {
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
    "image/bmp",
}

MAX_REQUEST_LEN = 256
MAX_PAYLOAD = 64 * 1024 * 1024
ACCEPT_TIMEOUT = 2.0
REQUEST_DEADLINE = 5.0
READ_TIMEOUT = 10


def log(msg):
    sys.stderr.write("clip_bridge: %s\n" % msg)
    sys.stderr.flush()


def parent_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def prepare_sock_dir(sock_dir):
    if os.path.islink(sock_dir):
        log("refusing: sock-dir %s is a symlink" % sock_dir)
        sys.exit(1)
    if os.path.exists(sock_dir):
        if not os.path.isdir(sock_dir):
            log("refusing: sock-dir %s is not a directory" % sock_dir)
            sys.exit(1)
        os.chmod(sock_dir, 0o700)
    else:
        os.makedirs(sock_dir, mode=0o700)
        os.chmod(sock_dir, 0o700)
    sock_path = os.path.join(sock_dir, "clip.sock")
    if os.path.islink(sock_path):
        log("refusing: socket path %s is a symlink" % sock_path)
        sys.exit(1)
    return sock_path


def pick_backend():
    if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-paste"):
        return "wayland"
    if os.environ.get("DISPLAY") and shutil.which("xclip"):
        return "x11"
    return None


def run_cmd(argv):
    try:
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=READ_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return None
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def list_types(backend):
    if backend == "wayland":
        out = run_cmd(["wl-paste", "--list-types"])
    elif backend == "x11":
        out = run_cmd(["xclip", "-selection", "clipboard", "-t", "TARGETS", "-o"])
    else:
        return None
    if out is None:
        return []
    types = []
    for line in out.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line in MIME_ALLOWLIST:
            types.append(line)
    return types


def read_mime(backend, mime):
    if backend == "wayland":
        return run_cmd(["wl-paste", "--no-newline", "--type", mime])
    if backend == "x11":
        return run_cmd(["xclip", "-selection", "clipboard", "-t", mime, "-o"])
    return None


def make_response(status, payload):
    return struct.pack(">B", status) + struct.pack(">I", len(payload)) + payload


def error_response(msg):
    payload = msg.encode("utf-8")[:4096]
    return make_response(0x01, payload)


def ok_response(payload):
    return make_response(0x00, payload)


def recv_exact(conn, n, deadline):
    buf = b""
    while len(buf) < n:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        conn.settimeout(remaining)
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def handle_conn(conn, backend):
    deadline = time.monotonic() + REQUEST_DEADLINE
    header = recv_exact(conn, 4, deadline)
    if header is None:
        return
    (n,) = struct.unpack(">I", header)
    if n == 0 or n > MAX_REQUEST_LEN:
        return
    body = recv_exact(conn, n, deadline)
    if body is None:
        return
    conn.settimeout(READ_TIMEOUT)
    try:
        op = body.decode("utf-8")
    except UnicodeDecodeError:
        return
    if op == "TYPES":
        types = list_types(backend)
        if types is None:
            conn.sendall(error_response("no clipboard backend"))
            return
        conn.sendall(ok_response("\n".join(types).encode("utf-8")))
        return
    if op.startswith("READ "):
        mime = op[len("READ "):]
        if mime not in MIME_ALLOWLIST:
            conn.sendall(error_response("mime not allowed"))
            return
        if backend is None:
            conn.sendall(error_response("no clipboard backend"))
            return
        data = read_mime(backend, mime)
        if data is None:
            conn.sendall(error_response("clipboard read failed"))
            return
        if len(data) > MAX_PAYLOAD:
            conn.sendall(error_response("clipboard payload too large"))
            return
        conn.sendall(ok_response(data))
        return
    conn.sendall(error_response("unsupported op"))


def serve(sock_path, parent_pid, sock_dir):
    if os.path.exists(sock_path) or os.path.islink(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(sock_path)
        os.chmod(sock_path, 0o600)
        srv.listen(4)
        srv.settimeout(ACCEPT_TIMEOUT)
        while True:
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                if not parent_alive(parent_pid):
                    log("parent pid %d gone, exiting" % parent_pid)
                    return 0
                if not os.path.isdir(sock_dir):
                    log("sock-dir %s vanished, exiting" % sock_dir)
                    return 0
                continue
            backend = pick_backend()
            try:
                handle_conn(conn, backend)
            except (OSError, socket.error):
                pass
            finally:
                conn.close()
    finally:
        try:
            os.unlink(sock_path)
        except OSError:
            pass
        srv.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sock-dir", required=True)
    parser.add_argument("--parent-pid", required=True, type=int)
    args = parser.parse_args()
    sock_path = prepare_sock_dir(args.sock_dir)
    return serve(sock_path, args.parent_pid, args.sock_dir)


if __name__ == "__main__":
    sys.exit(main())
