#!/usr/bin/env python3
import os
import socket
import struct
import sys

MAX_REQUEST_LEN = 256
MAX_PAYLOAD = 64 * 1024 * 1024
SOCK_TIMEOUT = 15.0


def default_sock():
    return os.environ.get("CBOX_CLIP_SOCK", "/run/cbox-clip/clip.sock")


def parse_args(argv):
    mode = None
    mime = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-l", "--list-types"):
            if mode is not None:
                return None
            mode = "list"
            i += 1
            continue
        if a in ("-n", "--no-newline"):
            i += 1
            continue
        if a == "--primary":
            return None
        if a in ("-t", "--type"):
            if i + 1 >= len(argv):
                return None
            if mode is not None:
                return None
            mode = "type"
            mime = argv[i + 1]
            i += 2
            continue
        if a.startswith("--type="):
            if mode is not None:
                return None
            mode = "type"
            mime = a[len("--type="):]
            i += 1
            continue
        return None
    if mode is None:
        return None
    return (mode, mime)


def connect(sock_path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(SOCK_TIMEOUT)
    try:
        s.connect(sock_path)
    except OSError:
        return None
    return s


def send_op(s, op):
    body = op.encode("utf-8")
    s.sendall(struct.pack(">I", len(body)) + body)


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def recv_response(s):
    header = recv_exact(s, 5)
    if header is None:
        return None
    status = header[0]
    (plen,) = struct.unpack(">I", header[1:5])
    if plen > MAX_PAYLOAD:
        return None
    payload = recv_exact(s, plen)
    if payload is None:
        return None
    return (status, payload)


def main():
    argv = sys.argv[1:]
    parsed = parse_args(argv)
    if parsed is None:
        sys.stderr.write("unsupported\n")
        return 1
    mode, mime = parsed
    sock_path = default_sock()
    s = connect(sock_path)
    if s is None:
        sys.stderr.write("cbox clipboard bridge not running\n")
        return 1
    try:
        if mode == "list":
            send_op(s, "TYPES")
            resp = recv_response(s)
            if resp is None:
                sys.stderr.write("cbox clipboard bridge not running\n")
                return 1
            status, payload = resp
            if status != 0x00:
                sys.stderr.write(payload.decode("utf-8", "replace") + "\n")
                return 1
            text = payload.decode("utf-8", "replace")
            if text:
                sys.stdout.write(text + "\n")
            return 0
        if not mime.startswith("image/"):
            sys.stderr.write("text paste goes through the terminal\n")
            return 1
        send_op(s, "READ %s" % mime)
        resp = recv_response(s)
        if resp is None:
            sys.stderr.write("cbox clipboard bridge not running\n")
            return 1
        status, payload = resp
        if status != 0x00:
            sys.stderr.write(payload.decode("utf-8", "replace") + "\n")
            return 1
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.flush()
        return 0
    except socket.timeout:
        sys.stderr.write("cbox clipboard bridge not running\n")
        return 1
    except OSError:
        sys.stderr.write("cbox clipboard bridge not running\n")
        return 1
    finally:
        s.close()


if __name__ == "__main__":
    sys.exit(main())
