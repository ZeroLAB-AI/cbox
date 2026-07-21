#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import selectors
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import unicodedata


NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
MAX_REQUEST = 1024 * 1024
MAX_DOCKER_JSON = 8 * 1024 * 1024
DANGEROUS_CAPS = {"ALL", "SYS_ADMIN", "SYS_MODULE", "SYS_RAWIO", "SYS_PTRACE", "DAC_READ_SEARCH"}


def safe_text(raw):
    value = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw)
    return "".join("?" if (ord(char) < 32 and char not in "\n\t") or 127 <= ord(char) <= 159 or unicodedata.category(char) == "Cf" else char for char in value)


def path_within(path, roots):
    candidate = os.path.realpath(path)
    for root in roots:
        try:
            if os.path.commonpath([candidate, root]) == root:
                return True
        except ValueError:
            continue
    return False


def safe_runtime_dir(path):
    absolute = os.path.abspath(path)
    if path != absolute or os.path.realpath(path) != absolute:
        raise PermissionError("runtime directory path is unsafe")
    os.makedirs(absolute, mode=0o700, exist_ok=True)
    info = os.lstat(absolute)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise PermissionError("runtime directory is unsafe")
    os.chmod(absolute, 0o700)
    return absolute


def docker_json(docker_bin, args):
    proc = subprocess.run(
        [docker_bin] + args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", "replace")[:1000] or "docker command failed")
    if len(proc.stdout) > MAX_DOCKER_JSON:
        raise RuntimeError("docker response exceeds limit")
    return json.loads(proc.stdout.decode("utf-8", "replace"))


def network_members(docker_bin, networks):
    members = {}
    for network in networks:
        value = docker_json(docker_bin, ["network", "inspect", network])
        if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
            raise RuntimeError("invalid network inspect response")
        containers = value[0].get("Containers")
        if not isinstance(containers, dict):
            continue
        for cid, rec in containers.items():
            if not isinstance(cid, str) or not isinstance(rec, dict):
                continue
            item = members.setdefault(cid, {"id": cid, "name": rec.get("Name") or cid[:12], "networks": [], "addresses": []})
            item["networks"].append(network)
            address = rec.get("IPv4Address")
            if isinstance(address, str) and address:
                item["addresses"].append(address)
    return members


def inspect_container(docker_bin, cid):
    value = docker_json(docker_bin, ["inspect", cid])
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        raise RuntimeError("invalid container inspect response")
    return value[0]


def unsafe_reason(doc, workspace_roots=()):
    state = doc.get("State") if isinstance(doc.get("State"), dict) else {}
    host = doc.get("HostConfig") if isinstance(doc.get("HostConfig"), dict) else {}
    config = doc.get("Config") if isinstance(doc.get("Config"), dict) else {}
    labels = config.get("Labels") if isinstance(config.get("Labels"), dict) else {}
    image = str(config.get("Image") or "")
    if not state.get("Running"):
        return "container is not running"
    if host.get("Privileged"):
        return "privileged container"
    for key in ("PidMode", "IpcMode", "UTSMode", "UsernsMode"):
        value = str(host.get(key) or "")
        if value == "host" or value.startswith("container:"):
            return "%s=%s" % (key, value)
    if host.get("NetworkMode") == "host":
        return "NetworkMode=host"
    caps = host.get("CapAdd") if isinstance(host.get("CapAdd"), list) else []
    if DANGEROUS_CAPS.intersection(str(x).upper() for x in caps):
        return "dangerous added capability"
    if host.get("Devices"):
        return "host device access"
    security = host.get("SecurityOpt") if isinstance(host.get("SecurityOpt"), list) else []
    if any("unconfined" in str(x).lower() for x in security):
        return "unconfined security profile"
    if labels.get("cbox.kind") or image.startswith("cbox-img:") or image.startswith("cbox-proxy"):
        return "cbox infrastructure container"
    if labels.get("cbox.inputs") or labels.get("com.docker.compose.service") == "proxy":
        if labels.get("cbox.inputs") or image.startswith("cbox-proxy"):
            return "cbox infrastructure container"
    mounts = doc.get("Mounts") if isinstance(doc.get("Mounts"), list) else []
    for mount in mounts:
        if not isinstance(mount, dict):
            continue
        source = str(mount.get("Source") or "")
        dest = str(mount.get("Destination") or "")
        if source == "/" or source.endswith("/docker.sock") or dest.endswith("/docker.sock"):
            return "host-control mount"
        if any(source == base or source.startswith(base + "/") for base in ("/proc", "/sys", "/dev")):
            return "host namespace mount"
        if any(dest == base or dest.startswith(base + "/") for base in ("/proc", "/sys", "/dev")):
            return "host namespace mount"
        if workspace_roots and mount.get("Type") == "bind" and not path_within(source, workspace_roots):
            return "bind mount outside workspace scope"
    return None


def scoped_containers(docker_bin, networks, workspace_roots):
    members = network_members(docker_bin, networks)
    result = {}
    for cid, item in members.items():
        try:
            doc = inspect_container(docker_bin, cid)
            item["blockedReason"] = unsafe_reason(doc, workspace_roots)
            item["image"] = str((doc.get("Config") or {}).get("Image") or "")
        except (RuntimeError, ValueError, json.JSONDecodeError) as exc:
            item["blockedReason"] = "inspect failed: %s" % exc
            item["image"] = ""
        result[cid] = item
    return result


def resolve_container(items, selector):
    if not isinstance(selector, str) or not NAME_RE.fullmatch(selector):
        raise ValueError("invalid container selector")
    matches = []
    for cid, item in items.items():
        if cid == selector or cid.startswith(selector) or item.get("name") == selector:
            matches.append(item)
    unique = {item["id"]: item for item in matches}
    if len(unique) != 1:
        raise ValueError("container selector is missing or ambiguous")
    return next(iter(unique.values()))


def validate_argv(value):
    if not isinstance(value, list) or not value or len(value) > 64:
        raise ValueError("argv must contain 1..64 items")
    total = 0
    result = []
    for item in value:
        if not isinstance(item, str) or not item or "\x00" in item or len(item.encode("utf-8")) > 8192:
            raise ValueError("invalid argv item")
        total += len(item.encode("utf-8"))
        result.append(item)
    if total > 65536:
        raise ValueError("argv exceeds limit")
    return result


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


def run_exec(docker_bin, container_id, argv, cwd, timeout, max_bytes):
    command = [docker_bin, "exec"]
    if cwd:
        command.extend(["--workdir", cwd])
    command.append(container_id)
    command.extend(["timeout", "-k", "2", "%ds" % timeout])
    command.extend(argv)
    proc = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ, "stdout")
    sel.register(proc.stderr, selectors.EVENT_READ, "stderr")
    chunks = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + timeout
    timed_out = False
    truncated = False
    while sel.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            stop_process(proc)
            break
        events = sel.select(min(remaining, 0.5))
        if not events and proc.poll() is not None:
            events = [(key, selectors.EVENT_READ) for key in list(sel.get_map().values())]
        for key, _ in events:
            data = os.read(key.fileobj.fileno(), 65536)
            if not data:
                sel.unregister(key.fileobj)
                continue
            used = len(chunks["stdout"]) + len(chunks["stderr"])
            room = max_bytes - used
            if room <= 0:
                truncated = True
                stop_process(proc)
                break
            chunks[key.data].extend(data[:room])
            if len(data) > room:
                truncated = True
                stop_process(proc)
                break
        if truncated:
            break
    try:
        rc = proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        stop_process(proc)
        rc = 124
    if timed_out:
        rc = 124
    if truncated:
        rc = 125
    return {
        "ok": not timed_out and not truncated,
        "rc": rc,
        "stdout": safe_text(chunks["stdout"]),
        "stderr": safe_text(chunks["stderr"]),
        "timedOut": timed_out,
        "truncated": truncated,
    }


def audit(path, record):
    record = dict(record)
    record["at"] = int(time.time())
    raw = (json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError("audit path is not a regular file")
        offset = 0
        while offset < len(raw):
            offset += os.write(fd, raw[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)


class Handler:
    def __init__(self, docker_bin, networks, workspace_roots, timeout, max_bytes, audit_path):
        self.docker_bin = docker_bin
        self.networks = networks
        self.workspace_roots = workspace_roots
        self.timeout = timeout
        self.max_bytes = max_bytes
        self.audit_path = audit_path

    def handle(self, request):
        if not isinstance(request, dict):
            raise ValueError("request must be an object")
        op = request.get("op")
        items = scoped_containers(self.docker_bin, self.networks, self.workspace_roots)
        if op == "list":
            return {"ok": True, "containers": sorted(items.values(), key=lambda x: x.get("name") or "")}
        if op != "exec":
            raise ValueError("unsupported operation")
        item = resolve_container(items, request.get("container"))
        if item.get("blockedReason"):
            raise PermissionError(item["blockedReason"])
        argv = validate_argv(request.get("argv"))
        cwd = request.get("cwd")
        if cwd is not None and (not isinstance(cwd, str) or not cwd.startswith("/") or "\x00" in cwd or len(cwd) > 1024):
            raise ValueError("cwd must be an absolute path")
        requested_timeout = request.get("timeout", self.timeout)
        if not isinstance(requested_timeout, int) or requested_timeout < 1:
            raise ValueError("invalid timeout")
        timeout = min(requested_timeout, self.timeout)
        argv_hash = hashlib.sha256(json.dumps(argv, ensure_ascii=True).encode("ascii")).hexdigest()[:16]
        result = run_exec(self.docker_bin, item["id"], argv, cwd, timeout, self.max_bytes)
        audit(self.audit_path, {
            "op": "exec",
            "container": item["id"],
            "name": item.get("name"),
            "argv0": argv[0],
            "argc": len(argv),
            "argvHash": argv_hash,
            "rc": result.get("rc"),
            "timedOut": result.get("timedOut"),
            "truncated": result.get("truncated"),
        })
        result["container"] = item
        return result


def read_request(conn):
    chunks = bytearray()
    deadline = time.monotonic() + 5
    while len(chunks) <= MAX_REQUEST:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("request read timed out")
        conn.settimeout(remaining)
        data = conn.recv(min(65536, MAX_REQUEST + 1 - len(chunks)))
        if not data:
            break
        chunks.extend(data)
        if b"\n" in data:
            break
    if len(chunks) > MAX_REQUEST:
        raise ValueError("request exceeds limit")
    line = bytes(chunks).split(b"\n", 1)[0]
    return json.loads(line.decode("utf-8"))


def write_response(conn, value):
    conn.sendall((json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))


def parent_alive(parent_pid, parent_start):
    if parent_pid <= 0:
        return True
    try:
        with open("/proc/%d/stat" % parent_pid, "r", encoding="ascii") as fh:
            raw = fh.read()
        tail = raw[raw.rindex(")") + 2:].split()
        return len(tail) > 19 and tail[19] == parent_start
    except (OSError, ValueError):
        return False


def serve(sock_dir, parent_pid, parent_start, handler):
    sock_dir = safe_runtime_dir(sock_dir)
    path = os.path.join(sock_dir, "bridge.sock")
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(8)
    server.settimeout(1)
    try:
        while parent_alive(parent_pid, parent_start):
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            with conn:
                try:
                    if hasattr(socket, "SO_PEERCRED"):
                        peer = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
                        _, peer_uid, _ = struct.unpack("3i", peer)
                        if peer_uid != os.getuid():
                            raise PermissionError("peer uid mismatch")
                    write_response(conn, handler.handle(read_request(conn)))
                except PermissionError as exc:
                    write_response(conn, {"ok": False, "error": safe_text(str(exc)), "kind": "denied"})
                except Exception as exc:
                    write_response(conn, {"ok": False, "error": safe_text(str(exc)), "kind": "invalid"})
    finally:
        server.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        try:
            os.rmdir(sock_dir)
        except OSError:
            pass


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--sock-dir", required=True)
    parser.add_argument("--parent-pid", type=int, required=True)
    parser.add_argument("--parent-start", required=True)
    parser.add_argument("--audit-path", required=True)
    parser.add_argument("--networks", nargs="+", required=True)
    parser.add_argument("--workspace-root", action="append", default=[])
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--max-bytes", type=int, default=10485760)
    parser.add_argument("--docker-bin", default="docker")
    args = parser.parse_args(argv)
    if not all(NAME_RE.fullmatch(x) for x in args.networks):
        raise ValueError("invalid network name")
    if args.timeout < 1 or args.timeout > 3600 or args.max_bytes < 1024 or args.max_bytes > 16777216:
        raise ValueError("invalid bridge limit")
    if not args.parent_start.isdigit():
        raise ValueError("invalid parent start time")
    docker_bin = args.docker_bin
    if os.path.sep not in docker_bin:
        docker_bin = shutil.which(docker_bin) or ""
    if not docker_bin or not os.path.isfile(docker_bin) or not os.access(docker_bin, os.X_OK):
        raise ValueError("docker CLI is unavailable")
    workspace_roots = []
    for root in args.workspace_root:
        value = os.path.realpath(root)
        if not os.path.isabs(root) or not os.path.isdir(value) or value == "/":
            raise ValueError("invalid workspace root")
        workspace_roots.append(value)
    sock_dir = os.path.abspath(args.sock_dir)
    audit_path = os.path.abspath(args.audit_path)
    if args.audit_path != audit_path:
        raise ValueError("invalid audit path")
    safe_runtime_dir(os.path.dirname(audit_path))
    handler = Handler(os.path.realpath(docker_bin), list(dict.fromkeys(args.networks)), list(dict.fromkeys(workspace_roots)), args.timeout, args.max_bytes, audit_path)
    serve(sock_dir, args.parent_pid, args.parent_start, handler)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write("cbox-container-exec: %s\n" % exc)
        sys.exit(2)
